#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v pvesh >/dev/null 2>&1; then
  echo "Error: pvesh not found. Run on a Proxmox node." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found. Please install jq (apt install jq)." >&2
  exit 1
fi

OUT_DIR="docs"
INV_FILE="$OUT_DIR/inventory.md"
DGM_FILE_MD="$OUT_DIR/diagram.md"

mkdir -p "$OUT_DIR"

echo "Querying cluster state..." >&2
NODES_JSON=$(pvesh get /cluster/resources --type node --output-format json)
GUESTS_JSON=$(pvesh get /cluster/resources --type vm --output-format json)

ts() { date -u +"%Y-%m-%d %H:%M:%SZ"; }

to_gib_int='def gib: ((. / 1073741824) | floor);'

echo "Writing $INV_FILE" >&2
{
  echo "# Infrastructure Inventory"
  echo
  echo "Generated: $(ts) from Proxmox API on the master node."
  echo
  echo "## Cluster Nodes"
  echo "$NODES_JSON" | jq -r "$to_gib_int [.[] | {node, maxcpu, maxmem: (.maxmem|gib), status}] | sort_by(.node)[] | \n  \"- \(.node) — \(.maxcpu) CPU, \(.maxmem) GiB RAM, status: \(.status)\""
  echo
  echo "## Running Guests"
  echo "- QEMU"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"qemu\" and .status==\"running\") | {vmid,name,node,maxmem:(.maxmem|gib), maxdisk:(.maxdisk|gib)}] | sort_by(.vmid)[] | \n  \"  - \(.vmid) \(.name) @ \(.node) — \(.maxmem) GiB RAM, \(.maxdisk) GiB disk\""
  echo "- LXC"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"lxc\" and .status==\"running\") | {vmid,name,node,tags}] | sort_by(.vmid)[] | \n  \"  - \(.vmid) \(.name) @ \(.node) — \(.tags // \"\")\""
  echo
  echo "## Stopped/Planned Guests"
  echo "- QEMU (stopped)"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"qemu\" and .status!=\"running\") | {vmid,name,node}] | sort_by(.vmid)[] | \n  \"  - \(.vmid) \(.name) @ \(.node)\"" | sed '/  - /!d' || true
  echo "- LXC (stopped)"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"lxc\" and .status!=\"running\") | {vmid,name,node,tags}] | sort_by(.vmid)[] | \n  \"  - \(.vmid) \(.name) @ \(.node) — \(.tags // \"\")\"" | sed '/  - /!d' || true
  echo
  echo "## Networking & Ingress"
  echo "- Public services via PCT 100 \`proxy\` (NGINX) → https://<service>.corbello.io"
  echo "- TLS: certbot (Let’s Encrypt) on \`proxy\` handles 80/443."
  echo "- DNS: Namecheap; manage via IaC to avoid drift."
  echo
  echo "## How To Refresh"
  echo "- Run: \`scripts/inventory/refresh.sh\` on the master node."
  echo "- Nodes: \`pvesh get /cluster/resources --type node --output-format json\`"
  echo "- Guests: \`pvesh get /cluster/resources --type vm --output-format json\`"
  echo "- VM list: \`qm list\`  |  LXC list: \`pct list\`"
} > "$INV_FILE"

echo "Writing $DGM_FILE_MD" >&2
{
  echo '```mermaid'
  echo 'graph TD'
  echo '  subgraph Proxmox_Cluster'
  echo "$NODES_JSON" | jq -r "$to_gib_int [.[] | {node, maxcpu, maxmem:(.maxmem|gib)}] | sort_by(.node)[] | \n  \"    subgraph \(.node) [\(.node) (\(.maxcpu)c/\(.maxmem)GiB)]\n    end\""
  echo "$GUESTS_JSON" | jq -r '[.[] | {type, vmid, name, node, status}] | sort_by(.node,.vmid)[] | \n  (if .type=="qemu" then \n    "    vm\(.vmid)[QEMU \(.vmid) \(.name)]" \n   else \n    "    lxc\(.vmid)[LXC \(.vmid) \(.name)]" \n   end) + (if .status=="running" then "" else ":::stopped" end)'
  echo '  end'
  echo
  echo 'classDef stopped fill:#eee,stroke:#999,stroke-dasharray: 3 3,color:#666;'
  if echo "$GUESTS_JSON" | jq -e '.[] | select(.vmid==100 and .type=="lxc")' >/dev/null; then
    echo 'lxc100 -->|"TLS + ingress"| public[Public *.corbello.io]'
  fi
  echo '```'
} > "$DGM_FILE_MD"

echo "Inventory refreshed: $INV_FILE and $DGM_FILE_MD"

