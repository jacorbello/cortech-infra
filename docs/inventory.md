# Infrastructure Inventory

Generated: 2026-01-26 15:50:00Z (manual update by Alastar)

## Cluster Nodes
- cortech — 12 CPU, 188 GiB RAM, status: online
- cortech-node1 — 4 CPU, 30 GiB RAM, status: online
- cortech-node2 — 4 CPU, 30 GiB RAM, status: online
- cortech-node3 — 96 CPU, 566 GiB RAM, status: **offline** (GPU node, Tesla T4)
- cortech-node5 — 8 CPU, 30 GiB RAM, status: online

## Running Guests

### QEMU VMs
- 101 homeassistant @ cortech — 4 GiB RAM, 32 GiB disk
- 200 k3s-srv-1 @ cortech — 8 GiB RAM, 40 GiB disk (K3s control-plane)
- 201 k3s-srv-2 @ cortech-node1 — 4 GiB RAM, 40 GiB disk (K3s control-plane)
- 202 k3s-srv-3 @ cortech-node2 — 4 GiB RAM, 40 GiB disk (K3s control-plane)
- 203 k3s-wrk-1 @ cortech-node5 — 8 GiB RAM, 60 GiB disk (K3s worker)
- 204 k3s-wrk-2 @ cortech — 8 GiB RAM, 60 GiB disk (K3s worker)
- 205 ollama @ cortech-node3 — 64 GiB RAM, 100 GiB disk (Ollama LLM, GPU passthrough) **[unavailable - node offline]**
- 206 k3s-wrk-3 @ cortech-node3 — 64 GiB RAM, 60 GiB disk (K3s worker, ephemeral/batch) **[unavailable - node offline]**

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
  - 115 infisical @ cortech-node1 — critical;secrets
  - 117 gha-runner-personal @ cortech — ci

## K3s Kubernetes Cluster

| Component | Value |
|-----------|-------|
| API VIP | 192.168.1.90 (kube-vip) |
| K3s Version | v1.34.3+k3s1 |
| HA Mode | Embedded etcd (3 servers) |

### Nodes
| Node | IP | Role | Proxmox Host |
|------|----|------|--------------|
| k3s-srv-1 | 192.168.1.91 | control-plane, etcd | cortech |
| k3s-srv-2 | 192.168.1.92 | control-plane, etcd | cortech-node1 |
| k3s-srv-3 | 192.168.1.93 | control-plane, etcd | cortech-node2 |
| k3s-wrk-1 | 192.168.1.94 | worker (core-app) | cortech-node5 |
| k3s-wrk-2 | 192.168.1.95 | worker (compute) | cortech |
| k3s-wrk-3 | 192.168.1.97 | worker (batch-compute, ephemeral) | cortech-node3 |

**Note:** k3s-wrk-3 is tainted (`node.kubernetes.io/lifecycle=ephemeral:NoSchedule`) for intermittent availability. Workloads must explicitly tolerate this taint.

### Services
| Service | URL |
|---------|-----|
| Rancher | https://rancher.corbello.io |
| Grafana | https://grafana.corbello.io |

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
