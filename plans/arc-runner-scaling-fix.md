# ARC Runner Scaling Fix

> **Status: COMPLETED (2026-03-25)**
> Both phases implemented. ARC v1 decommissioned, ARC v2 fully operational
> with listener-based per-job autoscaling across all repos.

## Problem Statement

PlotLens GitHub Actions runners are chronically under-scaled. The root cause is
two-fold:

1. **Metric mismatch:** The HorizontalRunnerAutoscaler (HRA) uses
   `TotalNumberOfQueuedAndInProgressWorkflowRuns`, which counts *workflow runs*
   (1-2 per event), not *workflow jobs* (up to 25 per event). A single PR
   triggers ci.yaml (13 self-hosted jobs) + test.yaml (1 job) = 14 jobs, but
   the HRA sees it as ~1 run and keeps replicas at the floor of 2.

2. **Shared runner pool:** PlotLens runners advertise the `jarvis-deploy` label
   (copy-paste from jarvis setup). PlotLens and Jarvis runners are
   interchangeable, but each HRA only watches its own repo's run count. A burst
   on one repo can starve the other without either HRA reacting.

### Secondary issues
- Ghost pods: ARC v1 occasionally creates runner pods that register locally but
  never connect to GitHub, reducing effective capacity.
- ARC v1 (`summerwind/actions-runner-controller:v0.27.6`) is deprecated and no
  longer maintained.

---

## Phase 1: Immediate Stabilization

**Goal:** Stop plotlens runner starvation without infrastructure changes.
**Scope:** cortech-infra repo (runner manifests) + plotlens repo (workflow labels).
**Risk:** Low — changes are additive and reversible.

### Step 1: Give plotlens its own runner label

**cortech-infra** — Update the plotlens RunnerDeployment labels:
```yaml
# k8s/actions-runner-system/plotlens-runner.yaml (new file, or patch live)
labels:
  - self-hosted
  - linux
  - plotlens-deploy   # was: jarvis-deploy
```

**plotlens repo** — Find-and-replace across all workflow files:
```
jarvis-deploy  →  plotlens-deploy
```

Files to update (all in `.github/workflows/`):
- ci.yaml (13 occurrences)
- build-push.yaml (11 occurrences)
- test.yaml (1 occurrence)
- pipeline-tests.yml (1)
- daily-integration-tests.yml (5)
- billing-gates.yml (4)
- website.yml (2)
- migrations.yaml (1)
- google-docs-addon-release.yaml (1)
- word-addin-release.yaml (1)
- build-base-images.yml (1)

**Order of operations:**
1. Deploy the runner with BOTH labels (`jarvis-deploy` + `plotlens-deploy`)
   temporarily so there's no gap.
2. Update all plotlens workflows to use `plotlens-deploy`.
3. Remove `jarvis-deploy` from the plotlens RunnerDeployment.

### Step 2: Switch HRA metric to PercentageRunnersBusy

Replace the plotlens HRA metric:
```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: HorizontalRunnerAutoscaler
metadata:
  name: plotlens-runner-autoscaler
  namespace: actions-runner-system
spec:
  scaleTargetRef:
    name: plotlens-runner
  minReplicas: 3          # was: 2 (plotlens is high-activity)
  maxReplicas: 10
  scaleDownDelaySecondsAfterScaleOut: 600  # was: 300 (avoid flapping)
  metrics:
    - type: PercentageRunnersBusy
      scaleUpThreshold: "0.75"
      scaleDownThreshold: "0.25"
      scaleUpFactor: "2"
      scaleDownFactor: "0.5"
```

**Why PercentageRunnersBusy:**
- Scales based on actual runner utilization, not broken queue counting.
- If 75%+ of runners are busy, doubles the count. If <25% busy, halves it.
- No dependency on GitHub API status accuracy.
- Works with ARC v1 out of the box.

### Step 3: Add the plotlens runner manifest to the repo

Currently the plotlens RunnerDeployment + HRA only exist as live kubectl
applies. Add them as tracked manifests in `k8s/actions-runner-system/` so
changes are versioned and reviewable.

Files to create:
- `k8s/actions-runner-system/plotlens-runner.yaml`
- `k8s/actions-runner-system/plotlens-runner-autoscaler.yaml`

### Step 4: Apply the same PercentageRunnersBusy fix to jarvis

Update the jarvis HRA to use `PercentageRunnersBusy` as well, since it has the
same undercounting problem. Also add its manifests to the repo.

---

## Phase 2: Migrate to ARC v2

**Goal:** Replace deprecated ARC v1 with GitHub's official ARC v2 for
listener-based autoscaling.
**Timeline:** After Phase 1 is stable (~1-2 weeks).
**Risk:** Medium — requires careful migration to avoid CI downtime.

### Why ARC v2 over webhook-based ARC v1

| Aspect | ARC v1 + Webhook | ARC v2 (listener) |
|--------|------------------|-------------------|
| Scaling trigger | GitHub webhook → exposed endpoint | Long-poll to GitHub (no inbound) |
| Counts | Workflow runs (inaccurate) | Individual jobs (accurate) |
| Maintenance | Deprecated, community-only | Official GitHub project |
| Infra required | Webhook endpoint + TLS + secret | None (outbound only) |
| Runner type | Persistent pods | Ephemeral by default |

### Migration Steps

#### 2.1: Deploy ARC v2 controller alongside v1

```bash
helm install arc \
  --namespace arc-systems \
  --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

This runs in a separate namespace (`arc-systems`) so it doesn't conflict with
the existing v1 controller in `actions-runner-system`.

#### 2.2: Create a GitHub App for ARC v2 authentication

ARC v2 strongly recommends GitHub App auth over PAT tokens:
1. Create a GitHub App in the `Family-Friendly-Inc` org (or `jacorbello` account).
2. Required permissions: Actions (read), Organization Self-hosted runners (read/write).
3. Install the app on all relevant repos.
4. Store the app ID, installation ID, and private key as a K8s secret.

```bash
kubectl create secret generic arc-github-app \
  --namespace arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALL_ID> \
  --from-file=github_app_private_key=<KEY_FILE>
```

#### 2.3: Create AutoscalingRunnerSets (one per repo)

Start with plotlens as the pilot:

```bash
helm install plotlens-runner \
  --namespace arc-runners \
  --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --set githubConfigUrl="https://github.com/Family-Friendly-Inc/plotlens" \
  --set githubConfigSecret="arc-github-app" \
  --set minRunners=3 \
  --set maxRunners=10 \
  --set containerMode.type="dind" \
  --set template.spec.containers[0].resources.requests.cpu="1" \
  --set template.spec.containers[0].resources.requests.memory="2Gi" \
  --set template.spec.containers[0].resources.limits.cpu="4" \
  --set template.spec.containers[0].resources.limits.memory="8Gi"
```

The runner set automatically:
- Registers runners with the label matching the installation name (`plotlens-runner`).
- Scales based on actual job assignments (listener-based, not polling).
- Creates ephemeral pods per job (no ghost pod problem).

#### 2.4: Update plotlens workflows to target ARC v2 runners

Update `runs-on` in all plotlens workflow files:
```yaml
runs-on: plotlens-runner   # ARC v2 scale set name
```

#### 2.5: Validate and migrate remaining repos

Once plotlens is stable on ARC v2 (~1 week):
1. Migrate `jarvis` (jacorbello/jarvis)
2. Migrate `jarvis-batch` (same repo, separate runner set for batch-compute nodes)
3. Migrate `moltbot-trading` (jacorbello/moltbot-trading)
4. Migrate `osint-core` (jacorbello/osint-core)
5. Migrate `cortech-infra` (jacorbello/cortech-infra)

#### 2.6: Decommission ARC v1

Once all repos are on ARC v2:
```bash
# Delete all v1 RunnerDeployments and HRAs
kubectl delete runnerdeployment --all -n actions-runner-system
kubectl delete horizontalrunnerautoscaler --all -n actions-runner-system

# Uninstall v1 controller
helm uninstall arc -n actions-runner-system

# Clean up namespace
kubectl delete namespace actions-runner-system
```

#### 2.7: Preserve custom runner features

Features from v1 that need equivalent v2 config:
- **hostAliases** (harbor.corbello.io → 192.168.1.100): Use
  `template.spec.hostAliases` in the scale set values.
- **kubectl init container**: Same pattern works in v2 pod templates.
- **SSH keys for cortech-infra**: Mount via `template.spec.volumes` +
  `initContainers`.
- **Node selectors / tolerations** (batch-compute): Set in
  `template.spec.nodeSelector` and `template.spec.tolerations`.
- **Docker-in-Docker**: Use `containerMode.type: "dind"` in v2.

---

## Rollback Plan

### Phase 1 rollback
- Revert plotlens workflow labels back to `jarvis-deploy`.
- Revert plotlens RunnerDeployment labels.
- Switch HRA metric back to `TotalNumberOfQueuedAndInProgressWorkflowRuns`.
- All changes are simple YAML edits with no state.

### Phase 2 rollback
- Workflow files still reference the old label? Re-deploy v1 RunnerDeployments.
- ARC v2 runner sets can be deleted without affecting v1.
- Both controllers can coexist indefinitely during migration.
