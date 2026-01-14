# Infrastructure Dashboards

Grafana dashboards for monitoring Proxmox and K3s infrastructure. All dashboards appear in the **Cortech** folder in Grafana.

## Dashboards

| Dashboard | Description | Key Metrics |
|-----------|-------------|-------------|
| **Proxmox Cluster Overview** | High-level cluster health | Nodes online, VMs/containers running, cluster CPU/memory |
| **Proxmox Node Resources** | Per-node resource utilization | CPU, memory, network I/O, disk I/O per node |
| **Proxmox Guests** | VM and LXC container monitoring | Guest CPU/memory, network traffic, status table |
| **K3s Cluster Health** | Kubernetes control plane health | API server, etcd, scheduler, node status |
| **Storage & Networking** | Cross-cutting infrastructure view | Proxmox storage, K8s PVCs, Traefik ingress |

## Data Sources

These dashboards use metrics from:

- **Prometheus** - Primary metrics store
- **Proxmox Exporter** - Proxmox VE metrics (`pve_*`)
- **kube-state-metrics** - Kubernetes object metrics
- **node-exporter** - K3s node metrics

## Proxmox Exporter

The Proxmox metrics are collected by `prometheus-pve-exporter` deployed in the `observability` namespace.

### Exporter Deployment

```
k8s/observability/exporters/proxmox-exporter/
├── deployment.yaml      # Exporter pod
├── service.yaml         # ClusterIP service
├── servicemonitor.yaml  # Prometheus scrape config
└── secret.yaml.example  # Credential template
```

### Required Proxmox API Token

Create a Proxmox API token with PVEAuditor role:

```bash
# On Proxmox host
pveum user add pve-exporter@pve -comment "Prometheus PVE Exporter"
pveum acl modify / -user pve-exporter@pve -role PVEAuditor
pveum user token add pve-exporter@pve prometheus --privsep=0
```

Create the Kubernetes secret:

```bash
kubectl create secret generic proxmox-exporter-credentials \
  --namespace=observability \
  --from-literal=user="pve-exporter@pve" \
  --from-literal=token_name="prometheus" \
  --from-literal=token_value="<TOKEN>"
```

## Common Metrics

### Proxmox Metrics (pve_*)

```promql
# Node status (1=up, 0=down)
pve_up{id=~"node/.*"}

# CPU usage ratio (0-1)
pve_cpu_usage_ratio{id=~"node/.*"}

# Memory usage
pve_memory_usage_bytes / pve_memory_size_bytes

# Guest status
pve_up{id=~"qemu/.*"}  # VMs
pve_up{id=~"lxc/.*"}   # Containers

# Storage utilization
pve_disk_usage_bytes / pve_disk_size_bytes
```

### K3s Metrics

```promql
# API server status
up{job="apiserver"}

# Node count and status
count(kube_node_info)
sum(kube_node_status_condition{condition="Ready", status="true"})

# etcd database size
etcd_mvcc_db_total_size_in_bytes

# Pod counts
count(kube_pod_info)
count(kube_pod_status_phase{phase="Running"} == 1)
```

## Adding New Dashboards

1. Create a new YAML file following the naming convention: `<component>.yaml`
2. Use the ConfigMap structure from existing dashboards
3. Set the `grafana_folder` annotation to `"Cortech"`
4. Apply with `kubectl apply -f <file>.yaml`
