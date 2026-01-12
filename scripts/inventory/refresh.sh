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

# jq helper to convert bytes to GiB (floor), handles null
to_gib_int='def gib: if . == null then 0 else ((. / 1073741824) | floor) end;'

echo "Writing $INV_FILE" >&2
{
  echo "# Infrastructure Inventory"
  echo
  echo "Generated: $(ts) from Proxmox API on the master node."
  echo
  echo "## Cluster Nodes"
  echo "$NODES_JSON" | jq -r "$to_gib_int [.[] | {node, maxcpu, maxmem: (.maxmem|gib), status}] | sort_by(.node)[] | \"- \(.node) — \(.maxcpu) CPU, \(.maxmem) GiB RAM, status: \(.status)\""
  echo
  echo "## Running Guests"
  echo "- QEMU"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"qemu\" and .status==\"running\") | {vmid,name,node,maxmem:(.maxmem|gib), maxdisk:(.maxdisk|gib)}] | sort_by(.vmid)[] | \"  - \(.vmid) \(.name) @ \(.node) — \(.maxmem) GiB RAM, \(.maxdisk) GiB disk\""
  echo "- LXC"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"lxc\" and .status==\"running\") | {vmid,name,node,tags}] | sort_by(.vmid)[] | \"  - \(.vmid) \(.name) @ \(.node) — \(.tags // \"\")\""
  echo
  echo "## Stopped/Planned Guests"
  echo "- QEMU (stopped)"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"qemu\" and .status!=\"running\") | {vmid,name,node}] | sort_by(.vmid)[] | \"  - \(.vmid) \(.name) @ \(.node)\"" | sed '/  - /!d' || true
  echo "- LXC (stopped)"
  echo "$GUESTS_JSON" | jq -r "$to_gib_int [.[] | select(.type==\"lxc\" and .status!=\"running\") | {vmid,name,node,tags}] | sort_by(.vmid)[] | \"  - \(.vmid) \(.name) @ \(.node) — \(.tags // \"\")\"" | sed '/  - /!d' || true
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

  # Render each node as a subgraph with its guests
  echo "$NODES_JSON" | jq -c "$to_gib_int [.[] | {node, maxcpu, maxmem:(.maxmem|gib)}] | sort_by(.node)[]" | while read -r n; do
    node=$(echo "$n" | jq -r .node)
    maxcpu=$(echo "$n" | jq -r .maxcpu)
    maxmem=$(echo "$n" | jq -r .maxmem)
    label="$node (${maxcpu}c/${maxmem}GiB)"
    if [ "$node" = "cortech-node3" ]; then
      label="$label GPU"
    fi
    echo "    subgraph $node [$label]"
    echo "$GUESTS_JSON" | jq -r --arg NODE "$node" '[
      .[] | select(.node==$NODE) | {type, vmid, name, status}
    ] | sort_by(.vmid)[] | (
      if .type=="qemu" then
        "      vm\(.vmid)[QEMU \(.vmid) \(.name)]"
      else
        "      lxc\(.vmid)[LXC \(.vmid) \(.name)]"
      end
    ) + (if .status=="running" then "" else ":::stopped" end)'
    echo "    end"
  done

  echo '  end'
  echo
  echo 'classDef stopped fill:#eee,stroke:#999,stroke-dasharray: 3 3,color:#666;'
  if echo "$GUESTS_JSON" | jq -e '.[] | select(.vmid==100 and .type=="lxc")' >/dev/null; then
    echo 'lxc100 -->|"TLS + ingress"| public[Public *.corbello.io]'
  fi
  echo '```'
} > "$DGM_FILE_MD"

echo "Inventory refreshed: $INV_FILE and $DGM_FILE_MD"

