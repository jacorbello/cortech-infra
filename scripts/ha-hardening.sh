#!/usr/bin/env bash
# Applies the Home Assistant hardening pass of 2026-08-17. Idempotent-ish: it
# backs up anything it overwrites and skips work already done.
#
# Run from the Proxmox master:  ssh root@192.168.1.52 "bash /tmp/ha-hardening.sh"
set -Eeuo pipefail

VMID=101
HA_CONF=/mnt/data/supervisor/homeassistant/configuration.yaml
NODE3=192.168.1.114
EXPORT_PATH=/storage-pool/ha-backups
STAMP=$(date +%Y%m%d-%H%M%S)

x() { qm guest exec -t "${1}" "${VMID}" -- /bin/sh -c "${2}"; }

echo "== 1/4 harden configuration.yaml"
x 120 "cp ${HA_CONF} ${HA_CONF}.bak-${STAMP}"
# shellcheck disable=SC2016
CONF_B64=$(base64 -w0 <<'YAML'

# Loads default set of integrations. Do not remove.
default_config:

# Jarvis AI Assistant Integration
homeassistant:
  packages:
    jarvis: !include packages/jarvis_attention.yaml

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.1.100
  # Brute-force lockout. HA is publicly exposed and is actively probed by
  # internet scanners. Caveat: LAN traffic arrives as 192.168.1.1 because the
  # router SNATs hairpin NAT to itself, so a failed login from inside the LAN
  # bans the whole LAN. Recover by removing the entry from
  # /mnt/data/supervisor/homeassistant/ip_bans.yaml and restarting core.
  ip_ban_enabled: true
  login_attempts_threshold: 5
YAML
)
x 120 "echo ${CONF_B64} | base64 -d > ${HA_CONF}"

echo "== 2/4 validate config"
x 600 "/usr/bin/ha core check --no-progress"

echo "== 3/4 restart core"
x 900 "/usr/bin/ha core restart --no-progress"
for _ in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://192.168.1.61:8123/ || true)
  [ "${code}" = "200" ] && break
  sleep 15
done
echo "core HTTP: ${code}"

echo "== 4/4 off-box backup target"
# HA has no S3 backend, so backups go to the node3 NFS server rather than MinIO.
ssh "root@${NODE3}" "mkdir -p ${EXPORT_PATH} && chown nobody:nogroup ${EXPORT_PATH} && \
  grep -q '^${EXPORT_PATH} ' /etc/exports || \
  echo '${EXPORT_PATH} 192.168.1.0/24(rw,sync,no_subtree_check,all_squash)' >> /etc/exports; \
  exportfs -ra"
# Note: the mount name is positional; there is no --name flag.
x 300 "/usr/bin/ha mounts add ha-backups --type nfs --usage backup \
  --server ${NODE3} --path ${EXPORT_PATH} --no-progress" || \
  echo "mount may already exist; check: ha mounts"

echo
echo "DONE. Remaining manual step:"
echo "  Settings > System > Backups > Automatic backups — set a schedule and"
echo "  pick 'ha-backups' as the location. HA has no CLI for the schedule."
