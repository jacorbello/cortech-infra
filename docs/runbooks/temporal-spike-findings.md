# Temporal Spike Findings (Phase 0)

**Date:** 2026-05-19
**Outcome:** GO
**Chart version:** `temporal-0.74.0` (app `1.30.3`)

## What Was Tested

- Deployed Temporal chart with bundled-Postgres disabled; instead ran a standalone `postgres:15` Deployment + Service in the same namespace (`temporal-spike`).
- Created `default` namespace via `temporal operator namespace create`.
- Started a `HelloWorldWorkflow` via `temporal workflow start` from within the admintools container (the `temporaliotest/samples-go-helloworld:latest` Docker Hub image referenced in the original plan was not used — that image reference is stale; the admintools path is more reliable and was used throughout).
- Restarted the frontend Deployment and confirmed workflow history survived.

---

## Resource Usage

### At idle (no workflows running)

| Pod | CPU | Memory |
|---|---|---|
| frontend | 6m | 47Mi |
| history | 21m | 187Mi |
| matching | 6m | 57Mi |
| worker | 6m | 51Mi |
| web | 1m | 8Mi |
| postgres | 7m | 137Mi |

> Source: T1 baseline captured after `helm upgrade` reached stable. Matches live `kubectl top` readings at start of T2 session (frontend 6m/50Mi, history 19m/200Mi, matching 7m/60Mi, worker 10m/52Mi, web 1m/13Mi, postgres 3m/139Mi — minor variance from metrics window).

### Under helloworld load

`kubectl top` sampled immediately after `temporal workflow start` returned:

| Pod | CPU | Memory |
|---|---|---|
| frontend | 9m | 55Mi |
| history | 24m | 200Mi |
| matching | 11m | 60Mi |
| worker | 8m | 52Mi |
| web | 1m | 13Mi |
| postgres | 7m | 140Mi |

**Observation:** The helloworld workflow is a single dispatch (no application worker consuming task queue tasks, so no activity/workflow execution beyond registration). The load delta is minimal — frontend +3m/+8Mi, history +3-5m/+13Mi, matching +4m/+3Mi. This is consistent with the overhead of accepting and persisting a workflow start event. Peak CPU pressure lands on `history` as expected.

---

## Recommended Production Values

Resource requests to bake into the Phase 2 ArgoCD-managed deploy. Values are rounded up to the next clean boundary (typically the nearest 32Mi or 64Mi step) with a 96Mi floor for all server components. `web` uses a 24Mi floor due to Go runtime baseline overhead (raw 1.5× of 8Mi idle = 12Mi is unrealistically low). Limits give 2–5× headroom above requests and are intentionally generous for Phase 2 until load-test data is available.

| Component | requests.cpu | requests.memory | limits.cpu | limits.memory |
|---|---|---|---|---|
| `server.frontend` | `50m` | `96Mi` | `200m` | `256Mi` |
| `server.history` | `50m` | `288Mi` | `200m` | `512Mi` |
| `server.matching` | `50m` | `96Mi` | `200m` | `256Mi` |
| `server.worker` | `25m` | `96Mi` | `100m` | `256Mi` |
| `web` | `10m` | `24Mi` | `50m` | `64Mi` |
| `postgres` | external — see LXC 114 provisioning notes below | — | — | — |

> **Assumption:** `history` is memory-hungry at idle (187-200Mi) because it caches shard state. The 288Mi request gives 50% headroom; the 512Mi limit should absorb moderate workflow volume. Revisit after Phase 2 load testing.

Helm values path for Phase 2:

```yaml
server:
  frontend:
    resources:
      requests:
        cpu: 50m
        memory: 96Mi
      limits:
        cpu: 200m
        memory: 256Mi
  history:
    resources:
      requests:
        cpu: 50m
        memory: 288Mi
      limits:
        cpu: 200m
        memory: 512Mi
  matching:
    resources:
      requests:
        cpu: 50m
        memory: 96Mi
      limits:
        cpu: 200m
        memory: 256Mi
  worker:
    resources:
      requests:
        cpu: 25m
        memory: 96Mi
      limits:
        cpu: 100m
        memory: 256Mi
web:
  resources:
    requests:
      cpu: 10m
      memory: 24Mi
    limits:
      cpu: 50m
      memory: 64Mi
```

For Postgres on LXC 114, provision a dedicated `temporal` database and user. No K8s resource values apply — LXC 114 is not a K8s workload. On the LXC side, reserve at least 1 GiB additional RAM for the `temporal` schema on top of the existing services already running on that container; the spike observed ~137–140Mi idle for the standalone `postgres:15` pod, but the shared LXC may see higher working-set pressure once existing tenants are co-located.

---

## Startup Behavior

- **`helm install` API ack to STATUS=deployed (Helm release record written; pods not yet running):** ~2 seconds
- **Time from `helm upgrade` (config fix) to all pods Running:** ~5 minutes (dominated by schema init job and Postgres readiness probe backoff)
- **Total time from first attempt to fully healthy:** ~14 minutes (includes initial mis-config discovery and fix)
- **Time to recover after `rollout restart` (frontend):** ~23 seconds (pod terminated + new pod reached Running)
- **State (workflow history) survived restart:** **yes** — RunId `019e40f9-2bb8-7538-9b43-9716e5a3d934` present in `workflow list` and `workflow describe` immediately after restart; `HistoryLength: 2`, `HistorySize: 333 bytes` unchanged

---

## K3s-Specific Gotchas

1. **Postgres is not bundled.** The `temporal` chart's internal Cassandra/Postgres options are disabled in the working config. A standalone `postgres:15` Deployment + Service was deployed separately in `temporal-spike`. For Phase 2, use external LXC 114 (existing shared Postgres). Create a dedicated `temporal` database and user there; do not run Postgres inside K3s.

2. **All pods landed on `k3s-wrk-3` (ephemeral GPU worker).** The chart has no explicit `nodeSelector`. Pods were scheduled there because `k3s-wrk-3` carries **no `nvidia.com/gpu:NoSchedule` taint** at present (`kubectl get node k3s-wrk-3 -o jsonpath='{.spec.taints}'` returns empty) — the taint documented in the architecture notes is not actually applied, so nothing prevented the scheduler from using the node. For Phase 2, add an explicit `nodeSelector` and/or `affinity` to pin pods to `k3s-wrk-1` (`role=core-app`); do not rely on a taint that may or may not be present:
   ```yaml
   server:
     frontend:
       nodeSelector:
         role: core-app
     history:
       nodeSelector:
         role: core-app
     matching:
       nodeSelector:
         role: core-app
     worker:
       nodeSelector:
         role: core-app
   web:
     nodeSelector:
       role: core-app
   ```

3. **`kubectl wait` reports false-negative on `web` and `worker` pods.** Neither exports a `Ready` pod condition despite containers being fully operational. `kubectl rollout status` works correctly. Do not use `kubectl wait --for=condition=ready` for these pods in CI or health scripts.

4. **`tctl` is removed in Temporal 1.30.x.** All CLI operations must use the `temporal` binary (ships in the admintools image). Key equivalents:
   - `tctl namespace list` → `temporal operator namespace list`
   - `tctl workflow list` → `temporal workflow list --namespace default`
   - `tctl workflow start` → `temporal workflow start --namespace default --type ... --task-queue ... --workflow-id ... --input ...`

5. **`default` namespace must be created manually.** Unlike some Temporal installations, the chart does not auto-provision a `default` namespace. Run after deploy:
   ```bash
   kubectl -n temporal-spike exec deploy/temporal-spike-admintools -- \
     temporal --address temporal-spike-frontend:7233 \
     operator namespace create --namespace default --retention 72h
     # 72h is appropriate for the spike; production should use 30d or more
   ```

6. **Chart requires explicit config override to avoid Cassandra defaults.** Two values are critical to avoid the embedded Cassandra configuration path:
   ```yaml
   server:
     setConfigFilePath: true
     configMapsToMount: sprig
   ```
   Without these, the server initializes with Cassandra defaults regardless of `persistence.sql` settings.

7. **Schema init job runs on every `helm upgrade`.** The `temporal-spike-schema-N` job re-runs the schema migration on each upgrade. This is idempotent but adds ~30s to upgrade time. Plan for this in any rolling-upgrade automation.

---

## Decision

**GO.** The spike demonstrates that Temporal 1.30.3 runs correctly on K3s with the following production requirements clearly understood:

- Use **external Postgres** (LXC 114, dedicated `temporal` database) — not in-cluster
- Add **explicit `nodeSelector: role: core-app`** to pin to `k3s-wrk-1`; do not rely on scheduler taint tolerance behavior
- Create **`default` namespace** as a post-install hook or ArgoCD sync wave
- Set `server.setConfigFilePath: true` and `server.configMapsToMount: sprig` in Helm values
- Bake in **resource requests/limits** from the table above
- Use the **`temporal` CLI**, not `tctl`

**Phase 2 production deploy:** ArgoCD Application in `temporal` namespace, Helm chart `temporal-0.74.0` (or latest stable 0.74.x), external Postgres on LXC 114 (`temporal` DB), explicit node affinity for `k3s-wrk-1`, and namespace create handled by an ArgoCD sync-wave 0 Job.
