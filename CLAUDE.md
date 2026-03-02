# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code for the **Cortech homelab** — a Proxmox cluster running K3s Kubernetes, services on `*.corbello.io`, with NGINX reverse proxy and Let's Encrypt TLS.

## Common Commands

```bash
make inventory          # Refresh docs/inventory.md and docs/diagram.md (must run on Proxmox node)
make init               # Bootstrap terraform and pre-commit hooks
make fmt                # Format HCL/YAML/shell
make lint               # Run tflint, ansible-lint, yamllint, shellcheck
make plan ENV=dev       # Terraform plan for an environment
make apply ENV=dev      # Terraform apply (manual approval)
```

SSH aliases on the developer machine connect to Proxmox nodes:
- `CORTECH` → `ssh root@192.168.1.52` (master)
- `CORTECH_NODE1` → `.72`, `CORTECH_NODE2` → `.74`, `CORTECH_NODE3` → `.114`

You can run remote commands via `ssh root@192.168.1.52 "<command>"`. Inventory refresh and `pvesh`/`kubectl` commands must run on the Proxmox master.

## Code Conventions

- **Indentation:** 2 spaces for HCL/YAML. No tabs.
- **Bash scripts:** Always start with `set -Eeuo pipefail`. Format with `shfmt`, lint with `shellcheck`.
- **Naming:** Lowercase-hyphenated everywhere (e.g., `proxy-core`, `k3s-srv-1`).
- **Terraform modules:** Keep small and idempotent; include `variables.tf`, `outputs.tf`, `versions.tf` per module.
- **Commits:** Conventional Commits required — `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`.
- **PRs:** Include summary, linked issue, risk/rollback, `terraform plan` output, and URLs/screenshots for `https://<service>.corbello.io` when relevant.
- **Secrets:** Never commit. Use SOPS/Vault; commit only encrypted files.

## Architecture

### Proxmox Cluster (5 nodes)

| Node | IP | Specs | Notes |
|------|-----|-------|-------|
| cortech (master) | 192.168.1.52 | 12 CPU, 188 GiB RAM | Primary node |
| cortech-node1 | 192.168.1.72 | 4 CPU, 30 GiB RAM | |
| cortech-node2 | 192.168.1.60 | 4 CPU, 30 GiB RAM | |
| cortech-node3 | 192.168.1.114 | 96 CPU, 566 GiB RAM | GPU node (Tesla T4), sometimes offline |
| cortech-node5 | 192.168.1.80 | 8 CPU, 30 GiB RAM | |

### K3s Kubernetes Cluster

- **API VIP:** `192.168.1.90` (kube-vip), K3s v1.34.3+k3s1, embedded etcd HA
- **3 server VMs** (200-202): k3s-srv-{1,2,3} at `.91-.93`, spread across cortech/node1/node2
- **2 worker VMs** (203-204): k3s-wrk-1 (`.94`, `role=core-app`), k3s-wrk-2 (`.95`, `role=compute`)
- **1 ephemeral worker** (206): k3s-wrk-3 (`.97`, GPU node, tainted `NoSchedule`)
- **K8s namespaces:** `observability`, `cattle-system` (Rancher), `argocd`, `harbor`, `jarvis` (Dify/chat), `plotlens`, `plotlens-website`, `sonarqube`, `infisical`, `actions-runner-system`, `platform`, `security`, `cert-manager`, plus project namespaces (`alastar`, `investigations`, `trading`)
- **Kubeconfig** at `/root/.kube/config` on cortech master

### Traffic Flow

```
Internet → corbello.ddns.net → PCT 100 "proxy" (NGINX + certbot TLS) → K3s Traefik / LXC services
```

All public services route through **LXC 100 (`proxy`)** which terminates TLS. K3s services are reached via Traefik on the API VIP.

### Guests Outside K3s

| ID | Type | Service | Node | Notes |
|----|------|---------|------|-------|
| 100 | LXC | NGINX reverse proxy | cortech | Critical — all public traffic |
| 101 | VM | Home Assistant | cortech | Smart home |
| 102 | LXC | WireGuard VPN | cortech | |
| 105 | LXC | Minecraft Bedrock | cortech | |
| 112 | LXC | n8n automation | cortech-node5 | |
| 113 | LXC | Postal (email) | cortech-node1 | |
| 114 | LXC | PostgreSQL | cortech | Shared DB |
| 116 | LXC | Redis | cortech | Shared cache |
| 119 | LXC | legal-api | cortech | |
| 120 | LXC | Uptime-Kuma | cortech | Monitoring |
| 121 | LXC | Keycloak (auth) | cortech | |
| 123 | LXC | MinIO (S3) | cortech | etcd backups + doc storage |
| 205 | VM | Ollama LLM | cortech-node3 | GPU passthrough, Tesla T4 |

### K8s Services (Ingress → Traefik)

| Service | URL | Namespace | Notes |
|---------|-----|-----------|-------|
| Rancher | https://rancher.corbello.io | cattle-system | Cluster management UI |
| Grafana | https://grafana.corbello.io | observability | Prometheus + Loki dashboards |
| ArgoCD | https://argocd.corbello.io | argocd | GitOps continuous delivery |
| Harbor | https://harbor.corbello.io | harbor | Container registry |
| Chat (Dify) | https://chat.corbello.io | jarvis | LLM chat platform |
| Dify API | https://api.chat.corbello.io | jarvis | Dify backend API |
| SonarQube | https://sonarqube.corbello.io | sonarqube | Code quality analysis |
| Infisical | https://infisical.corbello.io | infisical | Secrets management |
| PlotLens | https://plotlens.corbello.io | plotlens | Internal app |
| PlotLens site | https://plotlens.ai | plotlens-website | Public website (own domain) |

**Observability stack:** Prometheus (kube-prometheus-stack), Alertmanager, Loki, Promtail, Blackbox Exporter, Node Exporter — all in `observability` namespace.

**CI/CD:** GitHub Actions Runner Controller (ARC) in `actions-runner-system` with self-hosted runners. ArgoCD for GitOps deployments. NFS CSI driver for persistent storage.

### Backups

- etcd snapshots every 6 hours → MinIO S3 bucket `cortech/k3s-snapshots`
- Postgres/Redis: external to cluster, managed independently

## Repo Layout

| Directory | Purpose |
|-----------|---------|
| `k8s/` | Kubernetes manifests — Grafana dashboards (ConfigMaps), Proxmox exporter |
| `proxy/sites/` | NGINX server blocks for each `*.corbello.io` subdomain |
| `pct/` | Proxmox LXC container configs |
| `minio/` | MinIO docker-compose deployment |
| `docsync/` | Python daemon syncing docs from MinIO to Dify knowledge base |
| `scripts/` | Operations scripts — `inventory/refresh.sh` (Proxmox → docs), `dify-ingest.py` |
| `plans/` | Architecture plans (e.g., `k3s-cluster.md` — complete 8-stage deployment plan) |
| `docs/` | Auto-generated inventory, Mermaid diagrams, runbooks |
| `archive/` | Legacy/deprecated configs |

## Key Patterns

- **Grafana dashboards** are Kubernetes ConfigMaps in `k8s/observability/dashboards/` with label `grafana_dashboard: "1"` for sidecar auto-discovery. Template at `applications/_template.yaml`.
- **NGINX proxy configs** follow a consistent pattern: certbot-managed TLS, `proxy_pass` to upstream, standard security headers. Add new services by creating a new `.conf` in `proxy/sites/`.
- **Inventory docs** (`docs/inventory.md`, `docs/diagram.md`) are auto-generated by `scripts/inventory/refresh.sh` running on the Proxmox master. Do not hand-edit these.
- **Node labels** for K3s scheduling: use `role: core-app` for primary workloads, `role: compute` for background jobs, `role: batch-compute` for GPU/ephemeral work, `node-type: worker` for any worker.
- **Helm** is the primary K8s package manager. Key releases: `prometheus` (kube-prometheus-stack), `loki` (loki-stack), `rancher`, `harbor`, `arc` (GitHub Actions runners), `traefik`, `csi-driver-nfs`. Check live state with `ssh root@192.168.1.52 "helm list -A"`.
