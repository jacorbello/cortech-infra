# Infrastructure Inventory

Generated: 2026-05-03 17:48:39Z from Proxmox API on the master node.

## Cluster Nodes
- cortech — 12 CPU, 188 GiB RAM, status: online
- cortech-node1 — 4 CPU, 30 GiB RAM, status: online
- cortech-node2 — 4 CPU, 30 GiB RAM, status: online
- cortech-node3 — 96 CPU, 566 GiB RAM, status: online
- cortech-node5 — 8 CPU, 30 GiB RAM, status: online

## Running Guests
- QEMU
  - 101 homeassistant @ cortech — 4 GiB RAM, 32 GiB disk
  - 200 k3s-srv-1 @ cortech — 8 GiB RAM, 100 GiB disk
  - 201 k3s-srv-2 @ cortech-node1 — 4 GiB RAM, 40 GiB disk
  - 202 k3s-srv-3 @ cortech-node2 — 4 GiB RAM, 40 GiB disk
  - 203 k3s-wrk-1 @ cortech-node5 — 8 GiB RAM, 100 GiB disk
  - 204 k3s-wrk-2 @ cortech — 8 GiB RAM, 60 GiB disk
  - 206 k3s-wrk-3 @ cortech-node3 — 192 GiB RAM, 200 GiB disk
  - 207 k3s-wrk-4 @ cortech-node3 — 32 GiB RAM, 100 GiB disk
- LXC
  - 100 proxy @ cortech — critical
  - 103 wireguard-v2 @ cortech — community-script;critical;network;vpn
  - 112 n8n @ cortech-node5 — 
  - 114 postgres @ cortech — critical;db
  - 116 redis @ cortech — critical;db
  - 119 legal-api @ cortech — 
  - 120 uptime-kuma @ cortech — 
  - 121 keycloak @ cortech — 
  - 123 minio-01 @ cortech — minio;storage
  - 124 nomad @ cortech — services
  - 125 timemachine @ cortech — backup;storage

## Stopped/Planned Guests
- QEMU (stopped)
  - 205 ollama @ cortech-node3
  - 9000 k3s-template @ cortech
- LXC (stopped)
  - 102 wireguard @ cortech — community-script;network;vpn

## Networking & Ingress
- Public services via PCT 100 `proxy` (NGINX) → https://<service>.corbello.io
- TLS: certbot (Let’s Encrypt) on `proxy` handles 80/443.
- DNS: Namecheap; manage via IaC to avoid drift.

## How To Refresh
- Run: `scripts/inventory/refresh.sh` on the master node.
- Nodes: `pvesh get /cluster/resources --type node --output-format json`
- Guests: `pvesh get /cluster/resources --type vm --output-format json`
- VM list: `qm list`  |  LXC list: `pct list`
