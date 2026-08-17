#!/usr/bin/env bash
# Reports which LAN devices Home Assistant has adopted and which it has not.
#
# Joins HA's device registry against an nmap sweep of the LAN, on MAC rather
# than IP: several IoT devices sit in the DHCP pool and change address, so an IP
# join invents orphans that are actually adopted.
#
# Not every adopted device can be joined. Integrations that identify by
# accessory ID rather than MAC — homekit_controller, playstation_network,
# mobile_app — register no `connections` entry at all, so they are reported in
# their own section instead of being miscounted as unadopted. Integrations that
# do register a MAC (tplink, roku, asuswrt, brother) join normally.
#
# Read-only. This is a report, not a gate — it exits 0 whether or not orphans
# exist. Exit 2 means the homelab was unreachable, so "cannot reach it" is never
# mistaken for "nothing is adopted".
#
# Refreshes the adopted/orphan split in docs/smart-home-inventory.md.
set -Eeuo pipefail

MASTER=${MASTER:-root@192.168.1.52}
VMID=${VMID:-101}
SUBNET=${SUBNET:-192.168.1.0/24}
HA_STORAGE=/mnt/data/supervisor/homeassistant/.storage

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# The join lives in one place and is exercised by both the real run and
# --self-test, so the tested code path is the shipped code path.
cat > "${WORK}/join.py" << 'PYEOF'
import json
import os
import re
import sys

registry = json.loads(open(sys.argv[1]).read())["data"]["devices"]
scan_raw = open(sys.argv[2]).read()

# HA registers itself, its add-ons and its service integrations as "devices".
# They are not hardware on the LAN, so counting them as adopted-but-unmatchable
# inflates the figure — 11 of 18 entries before this filter.
# mobile_app is deliberately absent: a phone is real hardware on the LAN, even
# though the companion app registers no MAC for it.
NON_PHYSICAL = {
    "hassio", "sun", "backup", "met", "google_translate", "radio_browser",
    "shopping_list", "go2rtc", "analytics",
}

adopted_by_mac, mac_less = {}, []
for dev in registry:
    name = dev.get("name_by_user") or dev.get("name") or "(unnamed)"
    if any(domain in NON_PHYSICAL for domain, _ in dev.get("identifiers", [])):
        continue
    macs = [v.lower() for k, v in dev.get("connections", []) if k == "mac"]
    if macs:
        for mac in macs:
            adopted_by_mac[mac] = name
    else:
        mac_less.append(name)

# nmap -sn output, per host:
#   Nmap scan report for kasa-lamp (192.168.1.23)
#   MAC Address: 00:11:22:33:44:55 (Tp-link Technologies)
#
# Parsed instead of `ip neigh` because the master's ARP cache garbage-collects
# entries faster than a /24 sweep completes — it retained 17 of 70 hosts.
# The scanning host reports no MAC for itself; such blocks are skipped.
seen = {}
host_re = re.compile(r"Nmap scan report for (?:\S+ )?\(?(\d+\.\d+\.\d+\.\d+)\)?")
mac_re = re.compile(r"MAC Address: ([0-9A-Fa-f:]{17})\s*(?:\((.*)\))?")
current_ip = None
for line in scan_raw.splitlines():
    h = host_re.match(line.strip())
    if h:
        current_ip = h.group(1)
        continue
    m = mac_re.match(line.strip())
    if m and current_ip:
        seen[m.group(1).lower()] = (current_ip, (m.group(2) or "unknown").strip())
        current_ip = None

# Cluster guests are inventoried in docs/inventory.md and would swamp the smart
# -home signal here — roughly 25 of 71 hosts. Set HA_AUDIT_ALL=1 to keep them.
if not os.environ.get("HA_AUDIT_ALL"):
    skipped = {m for m, (_, v) in seen.items() if "Proxmox" in v}
    seen = {m: v for m, v in seen.items() if m not in skipped}
else:
    skipped = set()


def ipkey(ip):
    return [int(o) for o in ip.split(".")]


matched = sorted(
    ((ip, adopted_by_mac[mac], vendor) for mac, (ip, vendor) in seen.items() if mac in adopted_by_mac),
    key=lambda r: ipkey(r[0]),
)
orphans = sorted(
    ((ip, mac, vendor) for mac, (ip, vendor) in seen.items() if mac not in adopted_by_mac),
    key=lambda r: ipkey(r[0]),
)
absent = sorted(
    name for mac, name in adopted_by_mac.items() if mac not in seen
)

print(f"== adopted and on the network ({len(matched)})")
for ip, name, vendor in matched:
    print(f"  {ip:<16} {name}  [{vendor}]")

print(f"\n== on the network, NOT matched to Home Assistant ({len(orphans)})")
print("   Cross-check against the section below before treating one as unadopted.")
for ip, mac, vendor in orphans:
    print(f"  {ip:<16} {mac}  [{vendor}]")

print(f"\n== adopted but carries no MAC, so cannot be matched ({len(mac_less)})")
print("   HomeKit / PlayStation / companion-app devices. Verify these by hand.")
for name in sorted(mac_less):
    print(f"  {name}")

print(f"\n== adopted with a MAC but absent from the sweep ({len(absent)})")
for name in absent:
    print(f"  {name}")

if skipped:
    print(f"\n({len(skipped)} Proxmox cluster guests hidden; HA_AUDIT_ALL=1 to show)")
PYEOF

if [ "${1:-}" = "--self-test" ]; then
  cat > "${WORK}/reg.json" << 'EOF'
{"data": {"devices": [
  {"name": "Lamp", "connections": [["mac", "AA:BB:CC:00:00:01"]]},
  {"name": "Sleepy", "connections": [["mac", "aa:bb:cc:00:00:02"]]},
  {"name": "Upstairs", "connections": []}
]}}
EOF
  # Mixed-case MAC, a device the sweep cannot see, a MAC-less device, and a
  # host block with no MAC line (the scanning host). A regression in
  # case-folding, in the four-way split, or in the nmap parser fails here.
  cat > "${WORK}/scan.txt" << 'EOF'
Nmap scan report for kasa-lamp (192.168.1.23)
Host is up (0.010s latency).
MAC Address: aa:bb:cc:00:00:01 (Tp-link Technologies)
Nmap scan report for 192.168.1.99
Host is up (0.020s latency).
MAC Address: DE:AD:BE:EF:00:99 (Unknown Vendor)
Nmap scan report for 192.168.1.52
Host is up.
EOF
  out=$(python3 "${WORK}/join.py" "${WORK}/reg.json" "${WORK}/scan.txt")
  echo "${out}"
  echo
  fail=0
  check() { grep -q "$1" <<< "${out}" || { echo "FAIL: $2"; fail=1; }; }
  check "adopted and on the network (1)" "expected 1 matched (case-insensitive MAC join)"
  check "192.168.1.23 .*Lamp" "Lamp not matched to .23"
  check "NOT matched to Home Assistant (1)" "expected 1 orphan; the MAC-less scan host must not count"
  check "no MAC, so cannot be matched (1)" "expected Upstairs in the MAC-less section"
  check "absent from the sweep (1)" "expected Sleepy as adopted-but-absent"
  if grep -q "192.168.1.52" <<< "${out}"; then
    echo "FAIL: host block without a MAC line leaked into the report"
    fail=1
  fi
  [ "${fail}" -eq 0 ] || exit 1
  echo "self-test OK"
  exit 0
fi

if ! ssh -o ConnectTimeout=10 "${MASTER}" "qm status ${VMID}" > /dev/null 2>&1; then
  echo "ERROR: cannot reach VM ${VMID} via ${MASTER} — connection problem, not an empty registry."
  exit 2
fi

# qm guest exec wraps the payload in its own JSON envelope; unwrap to the
# registry itself before the join sees it.
# shellcheck disable=SC2029  # client-side expansion is intended
ssh "${MASTER}" "qm guest exec -t 60 ${VMID} -- /bin/cat ${HA_STORAGE}/core.device_registry" \
  | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["out-data"])' \
    > "${WORK}/reg.json"

# shellcheck disable=SC2029  # client-side expansion is intended
ssh "${MASTER}" "nmap -sn -PR ${SUBNET}" > "${WORK}/scan.txt" 2>/dev/null

python3 "${WORK}/join.py" "${WORK}/reg.json" "${WORK}/scan.txt"
