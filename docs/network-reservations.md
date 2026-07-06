# Network Reservations & Static IPs

Authoritative record of every homelab host's IP and MAC, so the LAN can be
rebuilt if the router/DHCP server is ever replaced again.

> **Not auto-generated.** Update by hand when a guest's IP/MAC changes. Source
> of truth for MACs is each guest's Proxmox config (`qm config <id>` /
> `pct config <id>`); IPs are the LXC `ip=` field, VM cloud-init `ipconfig0`,
> or (for DHCP hosts) the reservation.

## How addressing works here

Almost everything is **statically configured on the guest itself** — LXCs via
the Proxmox `ip=` net field, VMs via cloud-init `ipconfig0`. Those hosts set
their own IP and do **not** need a DHCP reservation. Only **Home Assistant**
and **n8n** use DHCP.

**The DHCP pool MUST NOT overlap the static range `.48–.153`.** If it does, the
router leases a static host's address (e.g. `.90`, `.96`, `.97`) to some other
client, causing IP conflicts — intermittent per-host packet loss, the kube-vip
VIP flapping, NFS mount timeouts, and hosts dropping off the LAN entirely.

**Router rules:**
- DHCP pool set to `.200–.250` (outside the static range).
- Reserve **Home Assistant → .61** and **n8n → .81** (the two DHCP hosts).
- Keep **.90 (kube-vip VIP)** out of the DHCP pool — it is a floating VIP with
  no fixed MAC (advertised by whichever k3s server holds it), so it cannot be a
  normal reservation.

## Host table

`⚠` = DHCP host — needs a router reservation.

| IP | Host | Proxmox ID | MAC | Config |
|----|------|-----------|-----|--------|
| .1   | router / gateway          | —        | `30:c5:99:c4:77:f8` | — |
| .48  | wireguard                 | LXC 102  | `BC:24:11:A8:01:28` | static |
| .49  | legal-api                 | LXC 119  | `BC:24:11:56:E5:63` | static |
| .52  | cortech (Proxmox master)  | host     | *(host NIC)*        | static |
| .59  | keycloak                  | LXC 121  | `BC:24:11:24:C3:85` | static |
| .60  | cortech-node2             | host     | `6c:4b:90:5c:b8:87` | static |
| .61  | homeassistant             | VM 101   | `BC:24:11:D8:80:01` | **DHCP ⚠** |
| .63  | uptime-kuma               | LXC 120  | `BC:24:11:F3:98:9F` | static |
| .72  | cortech-node1             | host     | `6c:4b:90:59:48:a2` | static |
| .80  | cortech-node5             | host     | `8c:ae:4c:cd:a3:cf` | static |
| .81  | n8n                       | LXC 112  | `BC:24:11:0C:94:86` | **DHCP ⚠** |
| .83  | postgres                  | LXC 114  | `BC:24:11:6B:33:C3` | static |
| .86  | redis                     | LXC 116  | `BC:24:11:89:CE:88` | static |
| .90  | **kube-vip API VIP**      | —        | *floating*          | **exclude from DHCP pool** |
| .91  | k3s-srv-1                 | VM 200   | `BC:24:11:57:24:87` | static |
| .92  | k3s-srv-2                 | VM 201   | `BC:24:11:51:77:F2` | static |
| .93  | k3s-srv-3                 | VM 202   | `BC:24:11:48:B9:4E` | static |
| .94  | k3s-wrk-1                 | VM 203   | `BC:24:11:AD:87:38` | static |
| .95  | k3s-wrk-2                 | VM 204   | `BC:24:11:51:85:BA` | static |
| .96  | ollama                    | VM 205   | `BC:24:11:A7:03:B7` | static |
| .97  | k3s-wrk-3                 | VM 206   | `BC:24:11:32:1E:EB` | static |
| .98  | k3s-wrk-4                 | VM 207   | `BC:24:11:F8:88:C2` | static |
| .100 | proxy (NGINX)             | LXC 100  | `BC:24:11:00:74:62` | static |
| .114 | cortech-node3 + NFS server| host     | `b4:96:91:6b:ed:39` | static |
| .118 | minio-01                  | LXC 123  | `BC:24:11:88:D3:DB` | static |
| .150 | nomad                     | LXC 124  | `BC:24:11:C5:8F:83` | static |
| .151 | timemachine               | LXC 125  | `BC:24:11:89:0F:F8` | static |
| .152 | odysseus                  | VM 208   | `BC:24:11:36:C4:CB` | static |
| .153 | claude-telegram           | LXC 126  | `BC:24:11:38:4C:7A` | static |

## Regenerating this table

MACs (per Proxmox host):
```bash
# VMs
for id in $(qm list | awk 'NR>1{print $1}'); do
  echo "VM $id $(qm config $id | awk -F': ' '/^name:/{print $2}') \
        $(qm config $id | grep -oiE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -1)"
done
# LXCs
for id in $(pct list | awk 'NR>1{print $1}'); do
  echo "LXC $id $(pct config $id | awk -F': ' '/^hostname:/{print $2}') \
        $(pct config $id | grep -oiE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -1)"
done
```

IPs: LXC → `pct config <id> | grep ip=`; VM → `qm config <id> | grep ipconfig0`
(or `qm agent <id> network-get-interfaces` for DHCP VMs with the guest agent).
