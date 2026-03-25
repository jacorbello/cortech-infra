# Node Maintenance Automation

**Date:** 2026-03-25
**Status:** Approved

## Problem

K3s nodes accumulate stale container images, journal logs, and containerd snapshots over time. Without automated cleanup, disk usage creeps toward pressure thresholds — srv-3 hit 82%, wrk-1 hit 83%, wrk-2 hit 80% within ~2 months. Manual SSH cleanup is unsustainable.

Additionally, no alerting rules exist — dashboards visualize resource usage with color thresholds, but nothing fires alerts when nodes approach danger zones.

## Solution

Two components deployed as raw Kubernetes manifests:

1. **DaemonSet** for periodic node-level cleanup
2. **PrometheusRules** for disk/memory/node health alerting

## Component 1: DaemonSet — `node-maintenance`

**Namespace:** `platform`

A DaemonSet running on every node (including tainted nodes like GPU workers) that performs cleanup every 12 hours. This is a new directory under `k8s/platform/` — the namespace already exists in the cluster.

### Container

- **Image:** `debian:bookworm-slim` (provides bash and coreutils; does not include systemd, so journal cleanup uses `find` instead of `journalctl`)
- **Privileged:** Yes (requires host access for containerd socket and journal)
- **Resources:** 50m CPU / 128Mi memory (requests and limits) — crictl image prune can spike briefly on nodes with many stale layers

### Cleanup Actions

1. `crictl rmi --prune` — remove unused container images
2. `find /var/log/journal -name '*.journal' -mtime +7 -delete` — remove journal files older than 7 days (using `find` instead of `journalctl` since `debian:bookworm-slim` lacks systemd)

### Environment Variables

```
CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
```

Required for `crictl` to find the containerd socket inside the container. The host socket at `/run/k3s/containerd/containerd.sock` is bind-mounted to `/run/containerd/containerd.sock` in the container.

### Schedule

Shell script with a sleep loop: run cleanup, log results with timestamps to stdout, sleep 12h, repeat. Stdout is picked up by Promtail into Loki for observability. Log format: `[YYYY-MM-DD HH:MM:SS] ACTION: result`.

### Host Mounts

| Host Path | Mount Path | Purpose |
|-----------|------------|---------|
| `/run/k3s/containerd/containerd.sock` | `/run/containerd/containerd.sock` | crictl socket (K3s path) |
| `/var/lib/rancher/k3s/agent/etc/crictl.yaml` | `/etc/crictl.yaml` | crictl config |
| `/var/log/journal` | `/var/log/journal` | journalctl vacuum target |
| `/usr/local/bin/k3s` | `/usr/local/bin/k3s` | k3s binary (crictl is a symlink to this) |
| `/usr/local/bin/crictl` | `/usr/local/bin/crictl` | crictl symlink |

Note: `/usr/local/bin/crictl` is a symlink to `k3s` on K3s nodes, so both the symlink and the `k3s` binary must be mounted.

### Tolerations

Wildcard toleration to run on all nodes regardless of taints:

```yaml
tolerations:
  - operator: Exists
```

### Node Selector

- `kubernetes.io/os: linux`

## Component 2: PrometheusRules — Node Health Alerts

**Namespace:** `observability`
**Manifest:** `k8s/observability/rules/node-health-alerts.yaml`

Deployed as a `PrometheusRule` CR. The CR metadata must include label `release: prometheus` to match the kube-prometheus-stack operator's `ruleSelector`.

### Alert Rules

| Alert | PromQL Expression | Severity | For |
|-------|------------------|----------|-----|
| `NodeDiskPressure` | `(1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}) * 100 > 80` | warning | 5m |
| `NodeDiskCritical` | `(1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}) * 100 > 90` | critical | 2m |
| `NodeMemoryPressure` | `(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10` | warning | 5m |
| `NodeMemoryCritical` | `(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 5` | critical | 2m |
| `NodeNotReady` | `kube_node_status_condition{condition="Ready",status="true"} == 0` | critical | 3m |
| `NodeMaintenanceFailed` | `kube_daemonset_status_number_unavailable{daemonset="node-maintenance",namespace="platform"} > 0` | warning | 10m |

### Labels and Annotations

**CR metadata labels:** `release: prometheus` (required for operator discovery)

**Alert labels:** `cluster: cortech`, `severity: warning|critical`

**Alert annotations:** `summary` (human-readable), `description` (includes `{{ $labels.instance }}` or `{{ $labels.node }}` for node identification)

### Visibility

Alerts are visible in Prometheus UI and Grafana alert panel. No AlertManager notification routing (out of scope — can be added later for Discord/Slack).

## File Layout

```
k8s/
  platform/
    node-maintenance/
      daemonset.yaml          # DaemonSet + ConfigMap with cleanup script
  observability/
    rules/
      node-health-alerts.yaml # PrometheusRule CR
```

Note: `k8s/platform/` is a new directory. The `platform` namespace already exists in the cluster but has no manifests in this repo yet.

## Out of Scope

- AlertManager notification routing (Discord/Slack)
- etcd backup verification
- Loki/Prometheus retention policies
- Helm chart packaging
