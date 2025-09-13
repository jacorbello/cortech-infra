# Infrastructure Inventory

This document captures the current Proxmox cluster, nodes, and guest workloads. It is generated from `pvesh`, `qm`, and `pct` on the master node and kept under version control for quick reference.

## Cluster Nodes
- cortech — 12 CPU, 188.6 GiB RAM, status: online
- cortech-node1 — 4 CPU, 30.3 GiB RAM, status: online
- cortech-node2 — 4 CPU, 30.3 GiB RAM, status: online
- cortech-node3 — 96 CPU, 566.2 GiB RAM, status: online
- cortech-node5 — 8 CPU, 31.0 GiB RAM, status: online (Tesla T4 GPU available; usually powered off)

## Running Guests
- QEMU
  - 101 homeassistant @ cortech — 4 GiB RAM, 32 GiB disk
- LXC
  - 100 proxy @ cortech — NGINX reverse proxy + certbot (public `*.corbello.io`)
  - 102 wireguard @ cortech — VPN gateway
  - 105 minecraft-bedrock @ cortech — games server
  - 106 radarr @ cortech — media automation
  - 107 qbittorrent @ cortech — media downloader
  - 108 jackett @ cortech — indexer
  - 109 plex @ cortech — media server
  - 110 sonarr @ cortech — media automation
  - 114 postgres @ cortech — database (shared)
  - 116 redis @ cortech — cache/message broker (critical)
  - 118 gha-runner-trading @ cortech — GitHub Actions runner

## Stopped/Planned Guests
- LXC (stopped)
  - 111 wordpress-ff @ cortech-node2 — site (family-friendly)
  - 112 n8n @ cortech-node5 — automation (start when needed)
  - 113 postal @ cortech-node1 — mail infra
  - 115 infisical @ cortech-node1 — secrets (critical)
  - 103/104 plotlens-ollama @ cortech-node3 — GPU templates

## Networking & Ingress
- Public services via PCT 100 `proxy` (NGINX) → `https://<service>.corbello.io`
- TLS: certbot (Let’s Encrypt) on `proxy` handles 80/443.
- DNS: Namecheap; manage via IaC to avoid drift.

## How To Refresh
- Nodes: `pvesh get /cluster/resources --type node --output-format json`
- Guests: `pvesh get /cluster/resources --type vm --output-format json`
- VM list: `qm list`  |  LXC list: `pct list`
