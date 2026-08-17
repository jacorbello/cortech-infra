#!/usr/bin/env bash
# Reports drift between this repo's proxy config and what is live on LXC 100.
#
# Only proxy/conf.d/ is treated as authoritative. Files in proxy/sites/ are
# rewritten in place by certbot on renewal, so they are compared for awareness
# but never fail the check.
#
# Read-only. Exits non-zero if an authoritative file drifted or is missing.
set -Eeuo pipefail

MASTER=${MASTER:-root@192.168.1.52}
CTID=${CTID:-100}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

live() { ssh "${MASTER}" "pct exec ${CTID} -- cat '$1'" 2>/dev/null; }

status=0

echo "== authoritative: proxy/conf.d/ (must match)"
for f in "${REPO_ROOT}"/proxy/conf.d/*; do
  name=$(basename "${f}")
  if ! live "/etc/nginx/conf.d/${name}" > /tmp/live-conf-$$ 2>/dev/null; then
    echo "  MISSING on proxy: ${name}"
    status=1
    continue
  fi
  if diff -q "${f}" /tmp/live-conf-$$ > /dev/null; then
    echo "  ok       ${name}"
  else
    echo "  DRIFTED  ${name}"
    diff -u "${f}" /tmp/live-conf-$$ | sed 's/^/    /' || true
    status=1
  fi
done
rm -f /tmp/live-conf-$$

echo
echo "== informational: proxy/sites/ (certbot rewrites these; never fails)"
# The live filenames do not always match the repo's. Match on server_name
# instead, which is what actually identifies a vhost.
for f in "${REPO_ROOT}"/proxy/sites/*.conf; do
  name=$(basename "${f}")
  host=$(awk '/server_name/ {print $2; exit}' "${f}" | tr -d ';')
  [ -z "${host}" ] && continue
  # Match the host anywhere in a server_name directive — a vhost may list
  # several names on one line, so an exact 'server_name <host>;' misses them.
  # Anchored to the directive so a cert path mentioning the host cannot match.
  # -R, not -r: sites-enabled entries are symlinks and -r will not follow them,
  # silently reporting every site as absent.
  esc=${host//./\\.}
  if ssh "${MASTER}" "pct exec ${CTID} -- grep -RlE 'server_name[^;]*[[:space:]]${esc}[[:space:];]' /etc/nginx/sites-enabled/" \
      > /dev/null 2>&1; then
    echo "  served   ${host}  (repo: ${name})"
  else
    echo "  NOT SERVED  ${host}  (repo: ${name}) — stale repo file, or vhost disabled"
  fi
done

echo
if [ "${status}" -eq 0 ]; then
  echo "conf.d in sync."
else
  echo "conf.d DRIFT DETECTED — reconcile before shipping proxy changes."
fi
exit "${status}"
