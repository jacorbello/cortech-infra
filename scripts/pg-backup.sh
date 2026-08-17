#!/usr/bin/env bash
# Dump Postgres databases from LXC 114 to the node3 NFS share.
#
# Runs ON the Proxmox master (needs pct + the NFS mount). Uses `pct exec` so no
# database password is ever stored in cron or passed on a command line.
#
#   ./pg-backup.sh              # dumps $DEFAULT_DBS
#   ./pg-backup.sh twenty       # dumps just one
#   DEST=/tmp/x ./pg-backup.sh  # override destination
set -Eeuo pipefail

CT="${CT:-114}"
DEST="${DEST:-/mnt/db-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DEFAULT_DBS="twenty outreach"

dbs=("$@")
if [ ${#dbs[@]} -eq 0 ]; then
  # shellcheck disable=SC2206  # deliberate word-split of a space-separated list
  dbs=(${DEFAULT_DBS})
fi

if [ ! -d "$DEST" ]; then
  echo "FATAL: $DEST does not exist — is the NFS share mounted?" >&2
  exit 1
fi

# A stale NFS handle presents as a readable-but-unwritable directory, which would
# otherwise let every dump 'succeed' into the void.
touch "$DEST/.write-probe" || { echo "FATAL: $DEST not writable" >&2; exit 1; }
rm -f "$DEST/.write-probe"

failed=0
for db in "${dbs[@]}"; do
  stamp=$(date +%F)
  file="${db}-${stamp}.sql.gz"
  tmp="/tmp/${file}"

  echo "==> ${db}"
  if ! pct exec "$CT" -- su postgres -c "pg_dump '${db}' | gzip -9 > '${tmp}'"; then
    echo "ERROR: pg_dump failed for ${db}" >&2
    pct exec "$CT" -- rm -f "$tmp" || true
    failed=1
    continue
  fi

  mkdir -p "${DEST}/${db}"
  pct pull "$CT" "$tmp" "${DEST}/${db}/${file}" --perms 600
  pct exec "$CT" -- rm -f "$tmp"

  # An empty or truncated dump is worse than no dump — it looks like a backup.
  if ! gzip -t "${DEST}/${db}/${file}" || [ ! -s "${DEST}/${db}/${file}" ]; then
    echo "ERROR: ${file} is empty or corrupt, removing" >&2
    rm -f "${DEST}/${db}/${file}"
    failed=1
    continue
  fi

  size=$(du -h "${DEST}/${db}/${file}" | cut -f1)
  echo "    ${file} (${size})"

  # ponytail: flat N-day retention. Add weekly/monthly tiers if a dump ever needs
  # to survive longer than the window.
  find "${DEST}/${db}" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
done

exit "$failed"
