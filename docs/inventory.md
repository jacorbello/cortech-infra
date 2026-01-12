# Infrastructure Inventory

Generated: 2025-09-13 02:02:22Z from Proxmox API on the master node.

## Cluster Nodes
- cortech — 12 CPU, 188 GiB RAM, status: online
- cortech-node1 — 4 CPU, 30 GiB RAM, status: online
- cortech-node2 — 4 CPU, 30 GiB RAM, status: online
- cortech-node3 — 96 CPU, 566 GiB RAM, status: offline
- cortech-node5 — 8 CPU, 30 GiB RAM, status: online

## Running Guests
- QEMU
  - 101 homeassistant @ cortech — 4 GiB RAM, 32 GiB disk
- LXC
  - 100 proxy @ cortech — critical
  - 102 wireguard @ cortech — community-script;network;vpn
  - 105 minecraft-bedrock @ cortech — games
  - 106 radarr @ cortech — media
  - 107 qbittorrent @ cortech — media
  - 108 jackett @ cortech — media
  - 109 plex @ cortech — media
  - 110 sonarr @ cortech — media
  - 114 postgres @ cortech — db
  - 116 redis @ cortech — critical;db
  - 118 gha-runner-trading @ cortech — 

## Stopped/Planned Guests
- QEMU (stopped)
- LXC (stopped)
  - 103 plotlens-ollama @ cortech-node3 — gpu;ollama
  - 104 plotlens-ollama @ cortech-node3 — gpu;ollama
  - 111 wordpress-ff @ cortech-node2 — family-friendly;website
  - 112 n8n @ cortech-node5 — 
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
