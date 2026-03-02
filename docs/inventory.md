# Infrastructure Inventory

Generated: 2026-03-01 from Proxmox API on the master node.

## Cluster Nodes
- cortech — 12 CPU, 188 GiB RAM, status: online
- cortech-node1 — 4 CPU, 30 GiB RAM, status: online
- cortech-node2 — 4 CPU, 30 GiB RAM, status: online
- cortech-node3 — 96 CPU, 566 GiB RAM, status: online (GPU node, Tesla T4)
- cortech-node5 — 8 CPU, 30 GiB RAM, status: online

## Running Guests

### QEMU VMs
- 101 homeassistant @ cortech — 4 GiB RAM, 32 GiB disk
- 200 k3s-srv-1 @ cortech — 8 GiB RAM, 100 GiB disk (K3s control-plane)
- 201 k3s-srv-2 @ cortech-node1 — 4 GiB RAM, 40 GiB disk (K3s control-plane)
- 202 k3s-srv-3 @ cortech-node2 — 4 GiB RAM, 40 GiB disk (K3s control-plane)
- 203 k3s-wrk-1 @ cortech-node5 — 8 GiB RAM, 100 GiB disk (K3s worker)
- 204 k3s-wrk-2 @ cortech — 8 GiB RAM, 60 GiB disk (K3s worker)
- 205 ollama @ cortech-node3 — 64 GiB RAM, 100 GiB disk (Ollama LLM, GPU passthrough)
- 206 k3s-wrk-3 @ cortech-node3 — 192 GiB RAM, 60 GiB disk (K3s worker, ephemeral/batch)

### LXC Containers
- 100 proxy @ cortech — critical
- 102 wireguard @ cortech — community-script;network;vpn
- 105 minecraft-bedrock @ cortech — games
- 112 n8n @ cortech-node5 — automation
- 113 postal @ cortech-node1 — mail
- 114 postgres @ cortech — db
- 116 redis @ cortech — critical;db
- 119 legal-api @ cortech — api
- 120 uptime-kuma @ cortech — monitoring
- 121 keycloak @ cortech — auth;identity
- 123 minio-01 @ cortech — minio;storage

## Stopped/Planned Guests
- LXC (stopped)
  - 111 wordpress-ff @ cortech-node2 — family-friendly;website
  - 117 gha-runner-personal @ cortech — ci

- QEMU (template)
  - 9000 k3s-template @ cortech — VM clone template (Debian 12 cloud-init)

## K3s Kubernetes Cluster

| Component | Value |
|-----------|-------|
| API VIP | 192.168.1.90 (kube-vip) |
| K3s Version | v1.34.3+k3s1 |
| HA Mode | Embedded etcd (3 servers) |
| Container Runtime | containerd 2.1.5-k3s1 |
| OS | Debian GNU/Linux 12 (bookworm) |

### Nodes
| Node | IP | Role | Label | Proxmox Host |
|------|----|------|-------|--------------|
| k3s-srv-1 | 192.168.1.91 | control-plane, etcd | — | cortech |
| k3s-srv-2 | 192.168.1.92 | control-plane, etcd | — | cortech-node1 |
| k3s-srv-3 | 192.168.1.93 | control-plane, etcd | — | cortech-node2 |
| k3s-wrk-1 | 192.168.1.94 | worker | core-app | cortech-node5 |
| k3s-wrk-2 | 192.168.1.95 | worker | compute | cortech |
| k3s-wrk-3 | 192.168.1.97 | worker | batch-compute | cortech-node3 |

**Note:** k3s-wrk-3 is tainted (`node.kubernetes.io/lifecycle=ephemeral:NoSchedule`) for intermittent availability. Workloads must explicitly tolerate this taint.

### Namespaces (active)
| Namespace | Purpose |
|-----------|---------|
| observability | Prometheus, Grafana, Loki, Blackbox Exporter |
| cattle-system | Rancher management |
| argocd | ArgoCD GitOps |
| harbor | Container registry |
| jarvis | Dify chat platform |
| plotlens | PlotLens application |
| plotlens-website | PlotLens public site (plotlens.ai) |
| sonarqube | Code quality analysis |
| infisical | Secrets management |
| actions-runner-system | GitHub Actions Runner Controller (ARC) |
| cert-manager | TLS certificate automation |
| platform | Shared platform services |
| security | Security tools |
| alastar | Personal project namespace |
| investigations | Investigation tools |
| trading | Trading applications |

### Helm Releases
| Release | Namespace | Chart | App Version |
|---------|-----------|-------|-------------|
| prometheus | observability | kube-prometheus-stack-80.14.3 | v0.87.1 |
| loki | observability | loki-stack-2.10.3 | v2.9.3 |
| blackbox | observability | prometheus-blackbox-exporter-11.7.0 | v0.28.0 |
| rancher | cattle-system | rancher-2.13.1 | v2.13.1 |
| harbor | harbor | harbor-1.18.1 | 2.14.1 |
| arc | actions-runner-system | actions-runner-controller-0.23.7 | 0.27.6 |
| traefik | kube-system | traefik-37.1.1 | v3.5.1 |
| csi-driver-nfs | kube-system | csi-driver-nfs-4.13.0 | 4.13.0 |
| plotlens | plotlens | plotlens-0.1.0 | 0.1.0 |

### Services
| Service | URL |
|---------|-----|
| Rancher | https://rancher.corbello.io |
| Grafana | https://grafana.corbello.io |
| ArgoCD | https://argocd.corbello.io |
| Harbor | https://harbor.corbello.io |
| Chat (Dify) | https://chat.corbello.io |
| Dify API | https://api.chat.corbello.io |
| SonarQube | https://sonarqube.corbello.io |
| Infisical | https://infisical.corbello.io |
| PlotLens | https://plotlens.corbello.io |
| PlotLens (public) | https://plotlens.ai |

### Backups
- etcd snapshots: Every 6 hours → MinIO (`cortech/k3s-snapshots`)

## Ollama LLM Server (QEMU 205)

GPU-accelerated LLM inference server on cortech-node3.

| Property | Value |
|----------|-------|
| IP | 192.168.1.96 |
| API Port | 11434 |
| GPU | Tesla T4 (16GB VRAM, PCI passthrough) |
| Models | llama3.2:3b, llama3.1:8b |

**Performance (warm):** ~580 tokens/sec prompt, ~73 tokens/sec generation

**API Access:**
```bash
curl http://192.168.1.96:11434/api/tags                    # List models
curl http://192.168.1.96:11434/api/generate -d '{"model":"llama3.2:3b","prompt":"Hello","stream":false}'
```

## Networking & Ingress
- Public services via PCT 100 `proxy` (NGINX) → https://<service>.corbello.io
- TLS: certbot (Let's Encrypt) on `proxy` handles 80/443.
- DNS: Namecheap; manage via IaC to avoid drift.
- K3s ingress: Traefik (internal), proxied through PCT 100 for public access

## How To Refresh
- Run: `scripts/inventory/refresh.sh` on the master node.
- Nodes: `pvesh get /cluster/resources --type node --output-format json`
- Guests: `pvesh get /cluster/resources --type vm --output-format json`
- VM list: `qm list`  |  LXC list: `pct list`
- K3s nodes: `kubectl get nodes`
