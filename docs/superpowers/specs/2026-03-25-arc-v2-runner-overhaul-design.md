# ARC v2 Runner Overhaul — Best Practices Audit & Fix

**Date:** 2026-03-25
**Status:** Draft
**Scope:** All 6 ARC v2 runner scale sets, controller, authentication, and related workflows

## Problem Statement

The ARC v2 runner environment suffers from four recurring failure modes:

1. **No matching runner (A):** Workflows queue indefinitely because `runs-on` labels don't route to the correct scale set
2. **Stale/offline runners (B):** Runners register with GitHub then appear as "offline" in the GitHub UI
3. **Pod evictions mid-job (C):** Ephemeral storage limits (4Gi) are too low for DinD Docker builds, causing pod eviction
4. **Ghost runners (E):** Orphaned runner registrations accumulate in GitHub Settings that never clean up

These are not independent issues — they form a causal chain: evictions (C) kill runners mid-job, GitHub can't deregister them ("job still running"), creating ghosts (E) that show as offline (B), while label misconfiguration independently causes routing failures (A).

## Root Cause Analysis

### Evidence Collected

- Controller logs show **59 "Runner is not finished yet, retrying in 30s"** entries in a single log window
- Pod events show `Pod ephemeral local storage usage exceeds the total limit of containers 4Gi` on plotlens runners
- Controller returns `400 Bad Request: job still running` when attempting to deregister evicted runners
- Plotlens listener crash-looped 6+ times in 1 minute during a helm upgrade (immediate update strategy)
- `osint-core/build-base-images.yml` uses `runs-on: self-hosted` — unroutable in ARC v2
- All 6 scale sets declare `scaleSetLabels: ["<name>", "self-hosted", "linux"]`, creating cross-match hazards
- Controller deployed with all default values (no resource limits, 2 concurrent reconciles, immediate update strategy)
- All runner pods land on k3s-wrk-3 by scheduler luck — no explicit node scheduling

### Root Causes

| # | Root Cause | Symptoms | Severity |
|---|-----------|----------|----------|
| 1 | Ephemeral storage limit 4Gi too low for DinD builds | C → E → B | Critical |
| 2 | Redundant `self-hosted`/`linux` in `scaleSetLabels` | A | High |
| 3 | `runs-on: self-hosted` in osint-core workflow | A | High |
| 4 | PAT auth (expiry risk, lower rate limits) | B | Medium |
| 5 | Controller defaults (immediate updates, low concurrency) | E, B | High |
| 6 | Inconsistent values across scale sets | Operational risk | Medium |

## Solution Design

### 1. GitHub App Authentication

**Replace PAT with GitHub App for all runner scale sets.**

- Create a single GitHub App on the `jacorbello` account
- Install on both `jacorbello` (personal repos) and `Family-Friendly-Inc` (org repos)
- Required permissions:
  - **Repository:** Actions (Read), Metadata (Read)
  - **Organization:** Self-hosted runners (Read & Write)
- Two Kubernetes secrets needed (one per installation):
  - `arc-github-app-jacorbello` — for cortech-infra, jarvis, moltbot-trading, osint-core
  - `arc-github-app-fff` — for plotlens (Family-Friendly-Inc org)
- Each secret contains: `github_app_id`, `github_app_installation_id`, `github_app_private_key`
- Retain old `arc-github-pat` secret as rollback until post-deploy verification passes, then delete

**Benefits:** Auto-refreshing tokens, 15k/hr API rate limit (vs 5k/hr PAT), no manual expiry management, fine-grained per-org scoping.

### 2. Label Cleanup

**Remove redundant labels from all `scaleSetLabels`.**

Before:
```yaml
scaleSetLabels:
  - "plotlens-runner"
  - "self-hosted"
  - "linux"
```

After:
```yaml
scaleSetLabels:
  - "plotlens-runner"
```

Applied to all 6 scale sets. The `self-hosted` and `linux` labels are auto-added by the runner binary at registration time but should not be in `scaleSetLabels` because they create cross-matching — any workflow using `runs-on: [self-hosted, linux]` would match every scale set.

**Workflow fix:** Change `osint-core/.github/workflows/build-base-images.yml`:
```yaml
# Before
runs-on: self-hosted

# After
runs-on: osint-core-runner
```

### 3. Ephemeral Storage & Resource Tuning

**PlotLens runner (DinD Docker builds):**
```yaml
resources:
  requests:
    cpu: "1"
    memory: 3Gi
    ephemeral-storage: 2Gi
  limits:
    cpu: "4"
    memory: 12Gi
    ephemeral-storage: 20Gi
```

**All other runners (no Docker builds):**
```yaml
resources:
  requests:
    cpu: 200m
    memory: 512Mi
    ephemeral-storage: 1Gi
  limits:
    cpu: "1"
    memory: 2Gi
    ephemeral-storage: 10Gi
```

**Graceful termination:** Add to all runner pods:
```yaml
# Pod-level grace period (covers both runner and DinD sidecar)
spec:
  terminationGracePeriodSeconds: 30

# Runner container env var
env:
  - name: RUNNER_GRACEFUL_STOP_TIMEOUT
    value: "15"
```

The `terminationGracePeriodSeconds` at the pod level ensures both the runner and the DinD sidecar get time to shut down cleanly. The `RUNNER_GRACEFUL_STOP_TIMEOUT` env var tells the runner process specifically to report back to GitHub within 15 seconds. Together these prevent ghost runners caused by abrupt pod termination.

### 4. Controller Tuning

**Upgrade controller helm values from defaults:**

```yaml
flags:
  logLevel: "info"
  runnerMaxConcurrentReconciles: 5
  updateStrategy: "eventual"
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

Key changes:
- **`updateStrategy: "eventual"`** — waits for running jobs to complete before recreating runners during helm upgrades, preventing mid-job kills and orphans. **Trade-off:** during upgrades, the listener and ephemeral runner set are removed immediately but not recreated until all pending/running jobs drain. This means no new jobs are picked up during the upgrade window. For scale sets with `minRunners > 0` (plotlens: 3, jarvis: 2), workflows may queue briefly during helm upgrades. This is acceptable given that upgrades are infrequent and the alternative (immediate) causes orphaned runners.
- **`runnerMaxConcurrentReconciles: 5`** — processes 5 runner lifecycle events simultaneously (up from 2), reducing the "retrying in 30s" pile-up during scale-down
- **`logLevel: "info"`** — reduces log volume (currently debug)
- **Resource limits** — prevents controller pod from being evicted

### 5. Standardize Values Files

**Consistent configuration across all 6 scale sets:**

| Setting | plotlens-runner | jarvis-runner | jarvis-runner-batch | cortech-infra-runner | moltbot-trading-runner | osint-core-runner |
|---------|----------------|---------------|--------------------|--------------------|----------------------|------------------|
| githubConfigSecret | arc-github-app-fff | arc-github-app-jacorbello | arc-github-app-jacorbello | arc-github-app-jacorbello | arc-github-app-jacorbello | arc-github-app-jacorbello |
| minRunners | 3 | 2 | 1 | 1 | 1 | 1 |
| maxRunners | 10 | 5 | 4 | 3 | 3 | 3 |
| nodeSelector | node-type: worker | node-type: worker | role: batch-compute | node-type: worker | node-type: worker | node-type: worker |
| hostAliases (Harbor) | yes | yes | yes | **yes (add)** | yes | yes |
| imagePullSecrets | harbor-registry | harbor-registry | harbor-registry | harbor-registry | harbor-registry | harbor-registry |
| containerMode | dind | dind | dind | dind | dind | dind |
| Custom image | harbor plotlens-runner:v1 | actions-runner:latest | actions-runner:latest | actions-runner:latest | actions-runner:latest | actions-runner:latest |
| serviceAccountName | — | — | — | — | moltbot-deployer | — |
| SSH keys | — | — | — | yes (proxy key) | — | — |
| Ephemeral toleration | yes | — | yes | — | — | — |

Changes from current state:
- `cortech-infra-runner`: add hostAliases for Harbor, add imagePullSecrets
- `jarvis-runner`: add imagePullSecrets (currently missing)
- `jarvis-runner-batch`: add imagePullSecrets (currently missing)
- `osint-core-runner`: add imagePullSecrets (currently missing)
- All: add `nodeSelector: {node-type: worker}` (except jarvis-runner-batch which keeps `role: batch-compute`)
- All: add `terminationGracePeriodSeconds: 30` and `RUNNER_GRACEFUL_STOP_TIMEOUT` env var
- All: bump resource limits per Section 3

**Node scheduling note:** The cluster has 4 worker nodes: wrk-1 (role: core-app), wrk-2 (role: compute), wrk-3 (role: batch-compute, ~192 GiB RAM VM allocation), and wrk-4 (role: gpu-inference, tainted `nvidia.com/gpu=present:NoSchedule`). The `nodeSelector: {node-type: worker}` matches all 4, but wrk-4's GPU taint will block runner pods that lack a matching toleration — effectively limiting overflow to wrk-1, wrk-2, and wrk-3. Since wrk-3 has by far the most capacity, the scheduler will naturally prefer it. No anti-affinity or topology spread is needed — wrk-3 can handle the full runner workload, and overflow to wrk-1/wrk-2 is acceptable for lighter runners. The plotlens-runner and jarvis-runner-batch tolerations for `node.kubernetes.io/lifecycle=ephemeral:NoSchedule` are retained for when wrk-3's ephemeral taint is active.

### 6. Ghost Runner Cleanup

**One-time post-deployment cleanup:**

```bash
# Repo-level offline runners
for repo in jacorbello/cortech-infra jacorbello/jarvis jacorbello/moltbot-trading \
            jacorbello/osint-core Family-Friendly-Inc/plotlens; do
  gh api "repos/${repo}/actions/runners" --jq '.runners[] | select(.status=="offline") | .id' | \
    xargs -I{} gh api -X DELETE "repos/${repo}/actions/runners/{}"
done

# Org-level offline runners (if any registered at org scope)
gh api "orgs/Family-Friendly-Inc/actions/runners" --jq '.runners[] | select(.status=="offline") | .id' | \
  xargs -I{} gh api -X DELETE "orgs/Family-Friendly-Inc/actions/runners/{}"
```

No ongoing automation needed — the root cause fixes (ephemeral storage, eventual updates, graceful termination) prevent ghost accumulation.

## Deployment Sequence

Brief downtime acceptable (user-approved).

1. **Fix osint-core workflow first** — PR to change `runs-on: self-hosted` → `runs-on: osint-core-runner` (must happen before label cleanup, otherwise the workflow has no matching runner)
2. **Create GitHub App** — manual step in browser
3. **Create Kubernetes secrets** — `arc-github-app-jacorbello` and `arc-github-app-fff`
4. **Upgrade controller** — `helm upgrade arc-v2` with new values
5. **Upgrade all 6 scale sets** — `helm upgrade` each with new values files
6. **Purge ghost runners** — run cleanup script against GitHub API
7. **Verify** — confirm all listeners healthy, runners registering, jobs routing correctly
8. **Delete old PAT secret** — remove `arc-github-pat` after verification passes

**Rollback:** If GitHub App auth fails, revert values files to use `githubConfigSecret: arc-github-pat` (retained until step 8). Controller tuning and resource changes are independent and do not need rollback.

## Out of Scope

- Migrating to org-level runner groups (future consideration)
- Switching from DinD to Kubernetes container mode (requires workflow changes)
- Upgrading ARC chart beyond 0.14.0 (already latest)
- Changes to the plotlens custom runner image (Containerfile)
- Monitoring/alerting for runner health (separate initiative)

## Risks

| Risk | Mitigation |
|------|-----------|
| GitHub App creation requires manual browser steps | Document step-by-step instructions |
| Brief runner unavailability during upgrade | Acceptable per user; schedule during low-activity window |
| Workflow using `self-hosted` label stops matching | Audit complete — only osint-core build-base-images.yml affected |
| Ephemeral storage increase may exceed node capacity | k3s-wrk-3 (566 GiB RAM) handles bulk of runners; wrk-1/wrk-2/wrk-4 have less capacity but only lighter runners would overflow there |
| GitHub App secret misconfigured breaks all scale sets | Retain old PAT secret as rollback; revert values files if App auth fails |
| k3s-wrk-4 (gpu-inference) receives runner pods | wrk-4 is tainted `NoSchedule` for GPU — runners won't schedule there without toleration (no action needed) |

## Success Criteria

- Zero "no runner matching labels" failures for 7 days post-deploy
- Zero ghost/offline runners accumulating in GitHub Settings
- No pod evictions due to ephemeral storage in arc-runners namespace
- Controller logs show no "Runner is not finished yet" retry storms
- All helm upgrades complete without orphaning running jobs
