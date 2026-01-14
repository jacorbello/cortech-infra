# K3s-on-Proxmox Cluster Plan

> Status: **Complete** (Core infrastructure ready)
> Created: 2026-01-14
> Updated: 2026-01-14

---

## Goals

* Dedicated **K3s cluster** running on **Proxmox VMs** (not LXCs) for application workloads.
* **HA control plane** (no single point of failure) + clean node/workload separation.
* A **management UI** accessible via browser (**Rancher** recommended).
* Keep stateful "base infra" (Postgres/Redis/MinIO/Proxy/Infisical) **outside** the cluster.

---

## Stage 0 — Decide the cluster shape ✅

> **Status:** Complete (2026-01-14)

### Topology

* **3× K3s server nodes** (embedded etcd HA)
* **2× K3s agent nodes** (workloads)
* **1× Virtual IP (VIP)** for the K3s API using **kube-vip**

K3s HA embedded etcd requires **3+ server nodes**. ([K3s][1])

### Node allocation

| Node | IP | Proxmox Host | vCPU | RAM | Disk |
|------|-----|--------------|------|-----|------|
| **K3S_API_VIP** | 192.168.1.90 | (kube-vip) | — | — | — |
| k3s-srv-1 | 192.168.1.91 | cortech | 4 | 8 GB | 40 GB |
| k3s-srv-2 | 192.168.1.92 | cortech-node1 | 2 | 4 GB | 40 GB |
| k3s-srv-3 | 192.168.1.93 | cortech-node2 | 2 | 4 GB | 40 GB |
| k3s-wrk-1 | 192.168.1.94 | cortech-node5 | 4 | 8 GB | 60 GB |
| k3s-wrk-2 | 192.168.1.95 | cortech | 4 | 8 GB | 60 GB |

> **Note:** Original .60-.74 range conflicted with Proxmox node bridge IPs (.52, .60, .72, .80). Revised to .90-.95.

### DNS strategy

| Hostname | Target | Notes |
|----------|--------|-------|
| `k3s-api.corbello.io` | 192.168.1.90 | Internal only (use /etc/hosts or IP directly) |
| `rancher.corbello.io` | PCT 100 → K3s Traefik | Public DNS CNAME → corbello.ddns.net |

**Traffic flow for Rancher/apps:**
```
Internet → corbello.ddns.net → PCT 100 (NGINX, TLS) → K3s Traefik (192.168.1.90:80)
```

### Decisions log

- [x] Pick node names + IPs: **192.168.1.90-95** range, VIP at **.90**
- [x] Pick DNS hostnames: Internal API via /etc/hosts, apps via PCT 100 proxy
- [x] Node placement: Servers spread across cortech, node1, node2 for HA

---

## Stage 1 — Proxmox prerequisites (networking + placement) ✅

> **Status:** Complete (2026-01-14)

### Best practices

* **Spread server nodes across different Proxmox hosts** (failure domain isolation).
* Use **VMs** for Kubernetes nodes (cleaner kernel/cgroups behavior vs LXC).
* Keep K3s on a **flat L2/L3 network** where nodes can reach each other directly.

### K3s network/port requirements (must be reachable)

| Port | Protocol | Purpose |
|------|----------|---------|
| 6443 | TCP | K3s server API (reachable by all nodes) |
| 8472 | UDP | Flannel VXLAN (node-to-node) |
| 2379-2380 | TCP | etcd server-to-server (HA) |
| 10250 | TCP | Kubelet metrics |

([K3s Requirements][2])

### Findings

**Firewall status:**
- Proxmox firewall: **disabled** (cluster + node level)
- Host iptables: **default ACCEPT** policy, no blocking rules
- All nodes on same L2 segment (vmbr0, 192.168.1.0/24)
- **Result:** All required ports open by default ✓

**Proxmox node bridge IPs (discovered):**
| Node | Bridge IP |
|------|-----------|
| cortech | 192.168.1.52 |
| cortech-node1 | 192.168.1.72 |
| cortech-node2 | 192.168.1.60 |
| cortech-node5 | 192.168.1.80 |

### Decisions log

- [x] Firewall: No changes needed (all ports open by default)
- [x] CNI mode: **Flannel VXLAN** (K3s default)
- [x] DNS: Added K3s entries to `/etc/hosts` on cortech
- [x] DNS: `rancher.corbello.io` CNAME already configured → corbello.ddns.net

### DNS entries added to cortech `/etc/hosts`

```
192.168.1.90 k3s-api.corbello.io k3s-api
192.168.1.91 k3s-srv-1.corbello.io k3s-srv-1
192.168.1.92 k3s-srv-2.corbello.io k3s-srv-2
192.168.1.93 k3s-srv-3.corbello.io k3s-srv-3
192.168.1.94 k3s-wrk-1.corbello.io k3s-wrk-1
192.168.1.95 k3s-wrk-2.corbello.io k3s-wrk-2
```

---

## Stage 2 — Build VM templates (repeatable + sane) ✅

> **Status:** Complete (2026-01-14)

### Template created

- **VMID 9000** `k3s-template` on cortech
- **Base image:** Debian 12 genericcloud (qcow2)
- **Cloud-init user:** `k3s`
- **SSH key:** root@cortech public key

### VMs deployed

| VM | VMID | Proxmox Host | IP | vCPU | RAM | Disk | Status |
|----|------|--------------|-----|------|-----|------|--------|
| k3s-srv-1 | 200 | cortech | 192.168.1.91 | 4 | 8 GB | 40 GB | ✅ Running |
| k3s-srv-2 | 201 | cortech-node1 | 192.168.1.92 | 2 | 4 GB | 40 GB | ✅ Running |
| k3s-srv-3 | 202 | cortech-node2 | 192.168.1.93 | 2 | 4 GB | 40 GB | ✅ Running |
| k3s-wrk-1 | 203 | cortech-node5 | 192.168.1.94 | 4 | 8 GB | 60 GB | ✅ Running |
| k3s-wrk-2 | 204 | cortech | 192.168.1.95 | 4 | 8 GB | 60 GB | ✅ Running |

### Verification

- [x] All VMs running on correct Proxmox hosts
- [x] SSH connectivity verified (`ssh k3s@192.168.1.9x`)
- [x] Inter-node connectivity verified (ping between all nodes)
- [x] Static IPs configured via cloud-init

### Decisions log

- [x] Created VM template with Debian 12 cloud image
- [x] Cloned and configured 5 VMs with appropriate specs
- [x] Migrated VMs to target nodes for failure domain isolation
- [x] Verified all nodes are communicating

---

## Stage 3 — Install K3s HA (embedded etcd) + kube-vip API VIP ✅

> **Status:** Complete (2026-01-14)

### Cluster details

| Component | Value |
|-----------|-------|
| K3s Version | v1.34.3+k3s1 |
| API VIP | 192.168.1.90 |
| API Endpoint | https://192.168.1.90:6443 |
| CNI | Flannel VXLAN (default) |
| Ingress | Traefik (default) |
| kube-vip | v0.8.7 (DaemonSet) |

### Cluster nodes

```
NAME        STATUS   ROLES                AGE   VERSION
k3s-srv-1   Ready    control-plane,etcd   ✅    v1.34.3+k3s1
k3s-srv-2   Ready    control-plane,etcd   ✅    v1.34.3+k3s1
k3s-srv-3   Ready    control-plane,etcd   ✅    v1.34.3+k3s1
k3s-wrk-1   Ready    <none>               ✅    v1.34.3+k3s1
k3s-wrk-2   Ready    <none>               ✅    v1.34.3+k3s1
```

### Core components running

- **kube-vip**: Running on all 3 control-plane nodes (HA VIP failover)
- **CoreDNS**: Running
- **Traefik**: Running (ingress controller)
- **metrics-server**: Running

### kubectl access

Kubeconfig installed at `/root/.kube/config` on cortech Proxmox host:
```bash
kubectl get nodes    # Works via VIP
```

### Decisions log

- [x] K3s installed with `--cluster-init` and `--tls-san 192.168.1.90`
- [x] kube-vip deployed as DaemonSet on control-plane nodes
- [x] All 3 server nodes joined with embedded etcd
- [x] All 2 worker nodes joined as agents
- [x] kubectl installed on Proxmox host with VIP-based kubeconfig
- [x] ServiceLB disabled (will use kube-vip or external LB)

---

## Stage 4 — Baseline cluster add-ons (minimum viable "platform") ✅

> **Status:** Complete (2026-01-14)

### Add-ons installed

| Add-on | Version | Status | Notes |
|--------|---------|--------|-------|
| Traefik | (K3s default) | ✅ Running | Ingress controller |
| cert-manager | v1.17.2 | ✅ Running | TLS certificate management |
| metrics-server | (K3s default) | ✅ Running | Resource metrics |
| CoreDNS | (K3s default) | ✅ Running | Cluster DNS |
| kube-vip | v0.8.7 | ✅ Running | API VIP (from Stage 3) |

### Namespaces created

| Namespace | Purpose |
|-----------|---------|
| `cattle-system` | Rancher components |
| `platform` | Shared platform services |
| `observability` | Prometheus, Grafana, Loki |
| `security` | Security tools |
| `cert-manager` | Certificate management (auto-created) |

### Decisions log

- [x] Traefik ingress confirmed running
- [x] cert-manager v1.17.2 installed via kubectl apply
- [x] metrics-server confirmed running
- [x] Created namespaces for platform organization

---

## Stage 5 — Management UI (Rancher) ✅

> **Status:** Complete (2026-01-14)

### Rancher deployment

| Component | Value |
|-----------|-------|
| URL | https://rancher.corbello.io |
| Version | Latest stable (Helm) |
| Namespace | cattle-system |
| TLS | External (PCT 100 + Let's Encrypt) |
| Bootstrap Password | `admin` |

### Architecture

```
Internet → rancher.corbello.io → PCT 100 (TLS) → Traefik:30278 → Rancher
```

### Configuration applied

1. **Rancher Helm install** with external TLS termination
2. **Traefik HelmChartConfig** to trust forwarded headers from PCT 100
3. **NGINX proxy** on PCT 100 with Let's Encrypt certificate
4. **X-Forwarded-Proto: https** header for proper protocol detection

### Access

- **URL**: https://rancher.corbello.io/dashboard/
- **Bootstrap password**: `admin`
- **First login**: Set new admin password, configure server URL

### Decisions log

- [x] Installed Rancher via Helm with `tls=external`
- [x] Configured PCT 100 NGINX proxy with TLS certificate
- [x] Configured Traefik to trust forwarded headers from proxy
- [x] Verified Rancher UI accessible at https://rancher.corbello.io
- [ ] Create admin user (first login task)
- [ ] Configure RBAC policies (post-setup task)

---

## Stage 6 — Node splitting strategy ✅

> **Status:** Complete (2026-01-14)

### Node labels applied

| Node | Labels | Purpose |
|------|--------|---------|
| k3s-srv-1 | `control-plane`, `etcd` | Control plane (no workloads) |
| k3s-srv-2 | `control-plane`, `etcd` | Control plane (no workloads) |
| k3s-srv-3 | `control-plane`, `etcd` | Control plane (no workloads) |
| k3s-wrk-1 | `role=core-app`, `node-type=worker` | Primary workloads (APIs, UIs) |
| k3s-wrk-2 | `role=compute`, `node-type=worker` | Background jobs, executors |

### Node selector examples

```yaml
# Schedule on core-app nodes
nodeSelector:
  role: core-app

# Schedule on compute nodes
nodeSelector:
  role: compute

# Schedule on any worker
nodeSelector:
  node-type: worker
```

### Taints

No taints applied (both workers schedulable). Taints can be added later when:
- Adding dedicated sandbox nodes for restricted execution
- Adding GPU nodes for ML workloads

### Decisions log

- [x] Applied `role=core-app` to k3s-wrk-1
- [x] Applied `role=compute` to k3s-wrk-2
- [x] Applied `node-type=worker` to both worker nodes
- [x] No taints applied (deferred until sandbox nodes added)

---

## Stage 7 — Observability ✅

> **Status:** Complete (2026-01-14)

### Stack deployed

| Component | Version | URL | Status |
|-----------|---------|-----|--------|
| Grafana | Latest | https://grafana.corbello.io | ✅ Running |
| Prometheus | Latest | (internal) | ✅ Running |
| Alertmanager | Latest | (internal) | ✅ Running |
| Loki | 2.6.1 | (internal) | ✅ Running |
| Promtail | Latest | (DaemonSet) | ✅ Running |
| Node Exporter | Latest | (DaemonSet) | ✅ Running |

### Access

- **Grafana URL**: https://grafana.corbello.io
- **Username**: `admin`
- **Password**: `admin` (change on first login)

### Datasources configured

| Datasource | Type | Purpose |
|------------|------|---------|
| Prometheus | metrics | Cluster and application metrics |
| Loki | logs | Log aggregation from all pods |

### Pre-built dashboards

kube-prometheus-stack includes dashboards for:
- Node health (CPU/RAM/Disk)
- Kubernetes cluster overview
- Pod resource usage
- etcd metrics
- CoreDNS metrics

### Decisions log

- [x] Deployed kube-prometheus-stack via Helm
- [x] Deployed Loki stack for log aggregation
- [x] Added Loki as Grafana datasource
- [x] Configured PCT 100 proxy with TLS for Grafana
- [x] Verified Grafana accessible at https://grafana.corbello.io

---

## Stage 8 — Backups & recovery (day-1 requirement) ✅

> **Status:** Complete (2026-01-14)

### etcd snapshot configuration

| Setting | Value |
|---------|-------|
| Schedule | Every 6 hours (`0 */6 * * *`) |
| Retention | 5 snapshots |
| S3 Endpoint | minio.corbello.io |
| S3 Bucket | cortech |
| S3 Folder | k3s-snapshots |
| Local Path | /var/lib/rancher/k3s/server/db/snapshots |

**Config file**: `/etc/rancher/k3s/config.yaml` on k3s-srv-1

### Backup verification

```bash
# List all snapshots (local + S3)
ssh k3s@192.168.1.91 "sudo k3s etcd-snapshot list"

# Take manual snapshot
ssh k3s@192.168.1.91 "sudo k3s etcd-snapshot save --name manual-backup"

# View snapshots in MinIO
mc ls cortech-minio/cortech/k3s-snapshots/
```

### Recovery procedures

#### Scenario 1: Single server node failure

If one server node fails, the cluster continues operating (etcd quorum maintained with 2/3 nodes).

**Recovery:**
1. Fix or rebuild the failed VM
2. Re-join to cluster: `curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server --server https://192.168.1.90:6443`

#### Scenario 2: Restore from snapshot (cluster corruption)

```bash
# Stop K3s on all server nodes
for node in 91 92 93; do ssh k3s@192.168.1.$node "sudo systemctl stop k3s"; done

# Restore on first server (from S3)
ssh k3s@192.168.1.91 "sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=s3://cortech/k3s-snapshots/<snapshot-name> \
  --etcd-s3 \
  --etcd-s3-endpoint=minio.corbello.io \
  --etcd-s3-bucket=cortech \
  --etcd-s3-folder=k3s-snapshots \
  --etcd-s3-access-key=<key> \
  --etcd-s3-secret-key=<secret>"

# Start K3s normally on first server
ssh k3s@192.168.1.91 "sudo systemctl start k3s"

# Re-join other servers (they will sync from restored leader)
for node in 92 93; do ssh k3s@192.168.1.$node "sudo systemctl start k3s"; done
```

#### Scenario 3: Full cluster rebuild ("nuke and pave")

```bash
# Uninstall K3s on all nodes
for node in 91 92 93; do ssh k3s@192.168.1.$node "sudo /usr/local/bin/k3s-uninstall.sh"; done
for node in 94 95; do ssh k3s@192.168.1.$node "sudo /usr/local/bin/k3s-agent-uninstall.sh"; done

# Re-run Stage 3 installation steps with --cluster-reset-restore-path for first server
# to restore from S3 snapshot
```

### What to back up

| Data | Method | Status |
|------|--------|--------|
| etcd snapshots | K3s built-in → MinIO S3 | ✅ Configured |
| Cluster manifests | Git repo (GitOps) | ⏳ Future |
| External data | Postgres dumps, Redis persistence | External to cluster |

### Decisions log

- [x] Configured etcd snapshots every 6 hours with 5 retention
- [x] Enabled S3 upload to MinIO (cortech/k3s-snapshots)
- [x] Verified manual snapshot upload works
- [x] Documented recovery procedures
- [ ] GitOps setup (future enhancement)

---

## "Definition of Done" checklist

- [x] `kubectl get nodes` shows 3 servers + 2 workers Ready
- [x] `https://rancher.corbello.io` loads and shows cluster + workloads
- [x] Metrics + logs are visible in Grafana / log UI
- [x] etcd snapshots are scheduled and stored (MinIO S3)
- [ ] Application workloads deployed and pinned to correct node roles (future)

---

## References

[1]: https://docs.k3s.io/datastore/ha-embedded "High Availability Embedded etcd"
[2]: https://docs.k3s.io/installation/requirements "Requirements"
[3]: https://kube-vip.io/ "kube-vip: Documentation"
[4]: https://kube-vip.io/docs/usage/k3s/ "K3s"
[5]: https://docs.k3s.io/add-ons/helm "Helm"
[6]: https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster "Install/Upgrade Rancher on a Kubernetes Cluster"
[7]: https://docs.k3s.io/installation/uninstall "Uninstalling K3s"
