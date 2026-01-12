# Infrastructure Inventory

Generated: 2026-01-12 14:10:54Z from Proxmox API on the master node.

## Cluster Nodes
- cortech — 12 CPU, 188 GiB RAM, status: online
- cortech-node1 — 4 CPU, 30 GiB RAM, status: online
- cortech-node2 — 4 CPU, 30 GiB RAM, status: online
- cortech-node3 — null CPU, 0 GiB RAM, status: offline
- cortech-node5 — 8 CPU, 30 GiB RAM, status: online

## Running Guests
- QEMU
  - 101 homeassistant @ cortech — 4 GiB RAM, 32 GiB disk
- LXC
  - 100 proxy @ cortech — critical
  - 102 wireguard @ cortech — community-script;network;vpn
  - 105 minecraft-bedrock @ cortech — games
  - 112 n8n @ cortech-node5 — 
  - 114 postgres @ cortech — db
  - 116 redis @ cortech — critical;db
  - 118 gha-runner-trading @ cortech — 
  - 119 legal-api @ cortech — 
  - 120 ai-trader @ cortech — 
  - 121 jarvis @ cortech — ai;assistant;critical
  - 122 jarvis-obs @ cortech — 
  - 123 minio-01 @ cortech — minio;storage
  - 124 dify-01 @ cortech — ai;critical;dify

## Stopped/Planned Guests
- QEMU (stopped)
- LXC (stopped)
  - 103 null @ cortech-node3 — gpu;ollama
  - 104 null @ cortech-node3 — gpu;ollama
  - 111 wordpress-ff @ cortech-node2 — family-friendly;website
  - 113 postal @ cortech-node1 — 
  - 115 infisical @ cortech-node1 — critical
  - 117 gha-runner-personal @ cortech — 

## Networking & Ingress
- Public services via PCT 100 `proxy` (NGINX) → https://<service>.corbello.io
- TLS: certbot (Let’s Encrypt) on `proxy` handles 80/443.
- DNS: Namecheap; manage via IaC to avoid drift.

## How To Refresh
- Run: `scripts/inventory/refresh.sh` on the master node.
- Nodes: `pvesh get /cluster/resources --type node --output-format json`
- Guests: `pvesh get /cluster/resources --type vm --output-format json`
- VM list: `qm list`  |  LXC list: `pct list`
