# Node Maintenance Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy automated node cleanup (image prune + journal vacuum every 12h) and PrometheusRule alerts for disk/memory/node health across all K3s nodes.

**Architecture:** A privileged DaemonSet in the `platform` namespace runs a shell script on a 12h sleep loop performing `crictl rmi --prune` and `find`-based journal cleanup (removing `.journal` files older than 7 days) on each node. A PrometheusRule CR in the `observability` namespace fires alerts at 80%/90% disk and 10%/5% memory thresholds.

**Tech Stack:** Kubernetes DaemonSet, ConfigMap, PrometheusRule CR (kube-prometheus-stack), debian:bookworm-slim, shell scripting.

**Spec:** `docs/superpowers/specs/2026-03-25-node-maintenance-design.md`

---

## File Structure

> **Note:** The spec describes a single `daemonset.yaml` containing both ConfigMap and DaemonSet. This plan splits them into separate files for easier review and maintenance. Both `k8s/platform/` and `k8s/observability/rules/` are new directories.

```
k8s/
  platform/
    node-maintenance/
      configmap.yaml    # Shell cleanup script mounted into DaemonSet
      daemonset.yaml    # Privileged DaemonSet with host mounts
  observability/
    rules/
      node-health-alerts.yaml  # PrometheusRule CR with 6 alert rules
```

---

### Task 1: Create the cleanup script ConfigMap

**Files:**
- Create: `k8s/platform/node-maintenance/configmap.yaml`

- [ ] **Step 1: Create the ConfigMap manifest**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-maintenance-script
  namespace: platform
  labels:
    app.kubernetes.io/name: node-maintenance
    app.kubernetes.io/component: cleanup
data:
  cleanup.sh: |
    #!/bin/bash
    set -Eeuo pipefail

    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    }

    run_cleanup() {
      log "CLEANUP_START: beginning node maintenance on $(hostname)"

      log "IMAGE_PRUNE: pruning unused container images"
      if output=$(crictl rmi --prune 2>&1); then
        log "IMAGE_PRUNE: completed successfully"
        echo "$output" | while IFS= read -r line; do
          [ -n "$line" ] && log "IMAGE_PRUNE: $line"
        done
      else
        log "IMAGE_PRUNE: failed with exit code $?"
        echo "$output" | while IFS= read -r line; do
          [ -n "$line" ] && log "IMAGE_PRUNE_ERROR: $line"
        done
      fi

      log "JOURNAL_VACUUM: removing journal files older than 7 days"
      # Use find instead of journalctl since debian:bookworm-slim lacks systemd
      deleted=0
      if [ -d /var/log/journal ]; then
        while IFS= read -r f; do
          rm -f "$f" && deleted=$((deleted + 1))
        done < <(find /var/log/journal -name '*.journal' -mtime +7 2>/dev/null)
        log "JOURNAL_VACUUM: removed $deleted journal files older than 7 days"
      else
        log "JOURNAL_VACUUM: /var/log/journal not found, skipping"
      fi

      log "CLEANUP_END: node maintenance complete on $(hostname)"
    }

    log "INIT: node-maintenance daemon starting, interval=12h"
    while true; do
      run_cleanup || log "ERROR: cleanup failed, continuing"
      log "SLEEP: next run in 12 hours"
      sleep 43200
    done
```

- [ ] **Step 2: Validate YAML syntax**

Run: `ssh root@192.168.1.52 "kubectl apply --dry-run=server -f -" < k8s/platform/node-maintenance/configmap.yaml`

Expected: `configmap/node-maintenance-script created (server dry run)`

- [ ] **Step 3: Commit**

```bash
git add k8s/platform/node-maintenance/configmap.yaml
git commit -m "feat: add node-maintenance cleanup script configmap"
```

---

### Task 2: Create the DaemonSet

**Files:**
- Create: `k8s/platform/node-maintenance/daemonset.yaml`

- [ ] **Step 1: Create the DaemonSet manifest**

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-maintenance
  namespace: platform
  labels:
    app.kubernetes.io/name: node-maintenance
    app.kubernetes.io/component: cleanup
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-maintenance
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-maintenance
        app.kubernetes.io/component: cleanup
    spec:
      priorityClassName: system-node-critical
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
      containers:
        - name: cleanup
          image: debian:bookworm-slim
          command: ["/bin/bash", "/scripts/cleanup.sh"]
          env:
            - name: CONTAINER_RUNTIME_ENDPOINT
              value: "unix:///run/containerd/containerd.sock"
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 50m
              memory: 128Mi
          securityContext:
            privileged: true
          volumeMounts:
            - name: cleanup-script
              mountPath: /scripts
              readOnly: true
            - name: containerd-sock
              mountPath: /run/containerd/containerd.sock
              readOnly: true
            - name: crictl-config
              mountPath: /etc/crictl.yaml
              readOnly: true
            - name: journal
              mountPath: /var/log/journal
            - name: k3s-binary
              mountPath: /usr/local/bin/k3s
              readOnly: true
            - name: crictl-binary
              mountPath: /usr/local/bin/crictl
              readOnly: true
      volumes:
        - name: cleanup-script
          configMap:
            name: node-maintenance-script
            defaultMode: 0755
        - name: containerd-sock
          hostPath:
            path: /run/k3s/containerd/containerd.sock
            type: Socket
        - name: crictl-config
          hostPath:
            path: /var/lib/rancher/k3s/agent/etc/crictl.yaml
            type: File
        - name: journal
          hostPath:
            path: /var/log/journal
            type: Directory
        - name: k3s-binary
          hostPath:
            path: /usr/local/bin/k3s
            type: File
        - name: crictl-binary
          hostPath:
            # Note: this is a symlink to k3s on K3s nodes
            path: /usr/local/bin/crictl
            type: File
```

- [ ] **Step 2: Validate YAML syntax with dry-run**

Run: `ssh root@192.168.1.52 "kubectl apply --dry-run=server -f -" < k8s/platform/node-maintenance/daemonset.yaml`

Expected: `daemonset.apps/node-maintenance created (server dry run)`

- [ ] **Step 3: Commit**

```bash
git add k8s/platform/node-maintenance/daemonset.yaml
git commit -m "feat: add node-maintenance daemonset for periodic cleanup"
```

---

### Task 3: Create PrometheusRule for node health alerts

**Files:**
- Create: `k8s/observability/rules/node-health-alerts.yaml`

- [ ] **Step 1: Create the PrometheusRule manifest**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: node-health-alerts
  namespace: observability
  labels:
    app.kubernetes.io/name: node-health-alerts
    app.kubernetes.io/component: alerting
    release: prometheus
spec:
  groups:
    - name: node-disk
      rules:
        - alert: NodeDiskPressure
          expr: >
            (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"}
            / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}) * 100 > 80
          for: 5m
          labels:
            severity: warning
            cluster: cortech
          annotations:
            summary: "Node {{ $labels.instance }} disk usage above 80%"
            description: "{{ $labels.instance }} root filesystem is {{ printf \"%.1f\" $value }}% full."
        - alert: NodeDiskCritical
          expr: >
            (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"}
            / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}) * 100 > 90
          for: 2m
          labels:
            severity: critical
            cluster: cortech
          annotations:
            summary: "Node {{ $labels.instance }} disk usage above 90%"
            description: "{{ $labels.instance }} root filesystem is {{ printf \"%.1f\" $value }}% full. Eviction imminent."
    - name: node-memory
      rules:
        - alert: NodeMemoryPressure
          expr: >
            (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10
          for: 5m
          labels:
            severity: warning
            cluster: cortech
          annotations:
            summary: "Node {{ $labels.instance }} memory available below 10%"
            description: "{{ $labels.instance }} has {{ printf \"%.1f\" $value }}% memory available."
        - alert: NodeMemoryCritical
          expr: >
            (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 5
          for: 2m
          labels:
            severity: critical
            cluster: cortech
          annotations:
            summary: "Node {{ $labels.instance }} memory available below 5%"
            description: "{{ $labels.instance }} has {{ printf \"%.1f\" $value }}% memory available. OOM risk."
    - name: node-health
      rules:
        - alert: NodeNotReady
          expr: >
            kube_node_status_condition{condition="Ready",status="true"} == 0
          for: 3m
          labels:
            severity: critical
            cluster: cortech
          annotations:
            summary: "Node {{ $labels.node }} is not ready"
            description: "{{ $labels.node }} has been in a non-ready state for more than 3 minutes."
        - alert: NodeMaintenanceFailed
          expr: >
            kube_daemonset_status_number_unavailable{daemonset="node-maintenance",namespace="platform"} > 0
          for: 10m
          labels:
            severity: warning
            cluster: cortech
          annotations:
            summary: "Node maintenance DaemonSet has unavailable pods"
            description: "{{ $value }} node-maintenance pod(s) are unavailable for more than 10 minutes."
```

- [ ] **Step 2: Validate YAML syntax with dry-run**

Run: `ssh root@192.168.1.52 "kubectl apply --dry-run=server -f -" < k8s/observability/rules/node-health-alerts.yaml`

Expected: `prometheusrule.monitoring.coreos.com/node-health-alerts created (server dry run)`

- [ ] **Step 3: Commit**

```bash
git add k8s/observability/rules/node-health-alerts.yaml
git commit -m "feat: add prometheus alerting rules for node health"
```

---

### Task 4: Deploy and verify

- [ ] **Step 1: Apply the ConfigMap and DaemonSet**

Run:
```bash
ssh root@192.168.1.52 "kubectl apply -f -" < k8s/platform/node-maintenance/configmap.yaml
ssh root@192.168.1.52 "kubectl apply -f -" < k8s/platform/node-maintenance/daemonset.yaml
```

Expected: Both resources created.

- [ ] **Step 2: Verify DaemonSet rolled out to all nodes**

Run: `ssh root@192.168.1.52 "kubectl -n platform get ds node-maintenance -o wide"`

Expected: `DESIRED` = `CURRENT` = `READY` = 7 (one pod per node: 3 servers + 4 workers).

- [ ] **Step 3: Check logs from one pod to confirm cleanup ran**

Run: `ssh root@192.168.1.52 "kubectl -n platform logs ds/node-maintenance --tail=20"`

Expected: Log lines showing `INIT`, `CLEANUP_START`, `IMAGE_PRUNE`, `JOURNAL_VACUUM`, `CLEANUP_END`, and `SLEEP`.

- [ ] **Step 4: Apply the PrometheusRule**

Run: `ssh root@192.168.1.52 "kubectl apply -f -" < k8s/observability/rules/node-health-alerts.yaml`

Expected: `prometheusrule.monitoring.coreos.com/node-health-alerts created`

- [ ] **Step 5: Verify Prometheus discovered the rules**

Run: `ssh root@192.168.1.52 "kubectl -n observability get prometheusrule node-health-alerts -o jsonpath='{.spec.groups[*].name}'"`

Expected: `node-disk node-memory node-health`

- [ ] **Step 6: Commit any adjustments**

If any adjustments were made during deploy, commit them.
