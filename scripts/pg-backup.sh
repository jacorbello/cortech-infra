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
DEFAULT_DBS="twenty outreach parley"

dbs=("$@")
if [ ${#dbs[@]} -eq 0 ]; then
  # shellcheck disable=SC2206  # deliberate word-split of a space-separated list
  dbs=(${DEFAULT_DBS})
fi

# An unmounted /mnt/db-backups leaves the bare mountpoint directory behind, which
# is present AND writable — so a plain -d/touch check would happily write every
# dump onto the master's root filesystem and slowly fill the node running the
# cluster. Only an actual mount will do.
if ! mountpoint -q "$DEST"; then
  echo "FATAL: $DEST is not a mountpoint — refusing to dump to local disk" >&2
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

  # Retention runs first and unconditionally: parked under a `continue` it would
  # never prune a database whose dump keeps failing, and that directory would
  # grow without bound while the script reported failure every night.
  # ponytail: flat N-day retention. Add weekly/monthly tiers if a dump ever needs
  # to survive longer than the window.
  if [ -d "${DEST}/${db}" ]; then
    find "${DEST}/${db}" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
  fi

  # `set -o pipefail` matters more than it looks: without it the exit status is
  # gzip's, not pg_dump's, so a failed dump still yields a *complete, valid*
  # gzip stream of partial SQL that sails through every check below.
  # `-s /bin/bash` because postgres' login shell may not support pipefail, and
  # `cd /tmp` silences the harmless 'could not change directory to /root'.
  if ! pct exec "$CT" -- su postgres -s /bin/bash -c \
    "set -o pipefail; cd /tmp && pg_dump '${db}' | gzip -9 > '${tmp}'"; then
    echo "ERROR: pg_dump failed for ${db}" >&2
    pct exec "$CT" -- rm -f "$tmp" || true
    failed=1
    continue
  fi

  mkdir -p "${DEST}/${db}"
  if ! pct pull "$CT" "$tmp" "${DEST}/${db}/${file}" --perms 600; then
    echo "ERROR: pct pull failed for ${db}" >&2
    # Always clear the in-container temp, or repeated failures fill LXC 114's
    # /tmp and the next dump truncates for lack of space.
    pct exec "$CT" -- rm -f "$tmp" || true
    rm -f "${DEST}/${db}/${file}"
    failed=1
    continue
  fi
  pct exec "$CT" -- rm -f "$tmp" || true

  # Empty, corrupt, or truncated-before-any-schema dumps are worse than no dump:
  # they look like backups. gzip -t alone can't catch a short-but-complete stream,
  # hence the schema probe.
  # `grep -c` (not -q/-m1): an early-exiting grep makes zcat take SIGPIPE, which
  # under `pipefail` fails the pipeline and condemns a perfectly good dump.
  tables=$(zcat "${DEST}/${db}/${file}" 2>/dev/null | grep -c 'CREATE TABLE' || true)
  if ! gzip -t "${DEST}/${db}/${file}" 2>/dev/null \
    || [ ! -s "${DEST}/${db}/${file}" ] \
    || [ "${tables:-0}" -eq 0 ]; then
    echo "ERROR: ${file} is empty, corrupt, or has no schema — removing" >&2
    rm -f "${DEST}/${db}/${file}"
    failed=1
    continue
  fi

  # --apparent-size reads st_size; plain `du` reports allocated blocks, which NFS
  # hasn't accounted for yet right after a write and misreports ~485K as 512.
  size=$(du --apparent-size -h "${DEST}/${db}/${file}" | cut -f1)
  echo "    ${file} (${size}, ${tables} tables)"
done

exit "$failed"
