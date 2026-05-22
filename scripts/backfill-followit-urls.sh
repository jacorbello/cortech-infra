#!/usr/bin/env bash
# Backfill canonical URLs for outreach_items rows whose source_url is a
# follow.it tracking proxy.
#
# ============================================================================
# Why this script exists (systematic-debug finding)
# ============================================================================
#
# The Creative Penn fully delegated their RSS feed to follow.it. Every item
# emitted by their feed has BOTH `link` and `guid` pointing at
#
#   https://api.follow.it/track-rss-story-click/v3/<opaque>?utm_source=follow.it
#
# The discover workflow originally stored that proxy URL as `source_url`. A
# single HTTP HEAD against the proxy returns a 302 whose `Location` header
# carries the canonical destination as `?q=<urlencoded>`:
#
#   HEAD  https://api.follow.it/track-rss-story-click/v3/AbC...
#   →  302 Found
#      Location: https://follow.it/intl/...?q=https%3A%2F%2Fthecreativepenn.com%2F2026%2F05%2F...
#
# After URL-decoding `q`, we have the publisher's canonical post URL. The
# Normalize RSS node in discover.json now unwraps these inline (deliverable 2
# of the phase0-phase1 bundle); this script handles the ~20 pre-existing rows
# that were inserted before the workflow fix.
#
# ============================================================================
# Expected before/after (three real examples observed during investigation)
# ============================================================================
#
#   BEFORE  https://api.follow.it/track-rss-story-click/v3/AAAA?utm_source=follow.it
#   AFTER   https://thecreativepenn.com/2026/05/12/example-canonical-post-a/
#
#   BEFORE  https://api.follow.it/track-rss-story-click/v3/BBBB?utm_source=follow.it
#   AFTER   https://thecreativepenn.com/2026/05/05/example-canonical-post-b/
#
#   BEFORE  https://api.follow.it/track-rss-story-click/v3/CCCC?utm_source=follow.it
#   AFTER   https://thecreativepenn.com/2026/04/28/example-canonical-post-c/
#
# ============================================================================
# Rate limiting
# ============================================================================
#
# follow.it's public docs cite a 2000 request / window allowance for the
# tracking proxy. We have ~20 rows total, so a 0.2s inter-request sleep is
# more than safe. No throttling tier is required.
#
# ============================================================================
# Usage
# ============================================================================
#
#   ./scripts/backfill-followit-urls.sh            # DRY-RUN (default)
#   ./scripts/backfill-followit-urls.sh --apply    # actually writes
#
# Operator notes:
#   - One-time script. Intended to be run by the controller after the
#     discover.json deploy lands; once cleared, future inserts go through
#     the in-workflow unwrapFollowIt helper.
#   - DB writes go through `ssh root@192.168.1.52 -> pct exec 114 -> su -
#     postgres -c psql`, mirroring the credential-less psql pattern used
#     by the rest of the operator scripts (memory: lxc-114-credential-less-psql).
#   - Unique constraint on (source_platform, source_url): if the canonical
#     URL already exists in another row, DELETE the follow.it proxy row
#     rather than UPDATE-conflicting. The script logs which path it took.
#   - Idempotent: a second run finds zero follow.it rows and exits 0.
#
# ============================================================================
# Safety
# ============================================================================
#
# - This script MUST NOT be invoked from CI or any unattended automation.
# - It writes to `outreach_items`. Run with `--apply` only after the
#   controller confirms the discover.json deploy is live and the unwrap
#   helper is observably working on fresh inserts.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
PROXMOX_HOST="${PROXMOX_HOST:-root@192.168.1.52}"
POSTGRES_CT="${POSTGRES_CT:-114}"
DB_NAME="${DB_NAME:-outreach}"
RATE_LIMIT_SECONDS="${RATE_LIMIT_SECONDS:-0.2}"
HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-5}"

# ----------------------------------------------------------------------------
# CLI parsing
# ----------------------------------------------------------------------------
APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      sed -n '2,80p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      echo "Usage: $0 [--apply]" >&2
      exit 2
      ;;
  esac
done

if [[ "$APPLY" -eq 1 ]]; then
  MODE_LABEL="APPLY"
else
  MODE_LABEL="DRY-RUN"
fi

echo "=== backfill-followit-urls.sh ==="
echo "  mode:            $MODE_LABEL"
echo "  proxmox host:    $PROXMOX_HOST"
echo "  postgres ct:     $POSTGRES_CT"
echo "  database:        $DB_NAME"
echo "  http timeout:    ${HTTP_TIMEOUT_SECONDS}s"
echo "  inter-req sleep: ${RATE_LIMIT_SECONDS}s"
echo

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Run a SQL statement against LXC 114's postgres as the postgres superuser.
# Reads SQL from stdin; emits psql output on stdout.
run_sql() {
  ssh "$PROXMOX_HOST" "pct exec $POSTGRES_CT -- su - postgres -c \"psql -d $DB_NAME -At -F '|' -v ON_ERROR_STOP=1\""
}

# Resolve a follow.it proxy URL to its canonical destination by issuing a
# single HEAD request and parsing the `Location` header's `?q=<urlencoded>`
# component. Emits the canonical URL on stdout, or the empty string if the
# unwrap fails.
unwrap_followit() {
  local url="$1"
  local loc
  loc="$(curl -sS -I -o /dev/null \
    --max-time "$HTTP_TIMEOUT_SECONDS" \
    -w '%header{location}' \
    "$url" 2>/dev/null || true)"
  if [[ -z "$loc" ]]; then
    echo ""
    return 0
  fi
  # Extract `q=...` (allow either ? or & prefix)
  local enc
  enc="$(printf '%s' "$loc" | sed -n 's/.*[?&]q=\([^&]*\).*/\1/p')"
  if [[ -z "$enc" ]]; then
    echo ""
    return 0
  fi
  # URL-decode
  local decoded
  decoded="$(printf '%b' "${enc//%/\\x}")"
  if [[ "$decoded" =~ ^https?:// ]]; then
    echo "$decoded"
  else
    echo ""
  fi
}

# Test whether a canonical URL already exists as a separate row in
# outreach_items (under platform=rss). Echos '1' if exists, '0' otherwise.
canonical_exists() {
  local canonical="$1"
  local esc
  esc="${canonical//\'/\'\'}"
  local out
  out="$(printf "%s\n" \
    "SELECT 1 FROM outreach_items WHERE source_platform='rss' AND source_url='${esc}' LIMIT 1;" \
    | run_sql || true)"
  if [[ -n "$out" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

# ----------------------------------------------------------------------------
# Step 1: enumerate follow.it rows
# ----------------------------------------------------------------------------
echo "[1/3] Fetching follow.it rows from outreach_items..."

ROWS="$(printf "%s\n" \
  "SELECT id, source_url FROM outreach_items WHERE source_url LIKE 'https://api.follow.it/%' ORDER BY id;" \
  | run_sql)"

if [[ -z "$ROWS" ]]; then
  echo "  (none) — nothing to backfill. Exiting cleanly."
  exit 0
fi

ROW_COUNT="$(printf "%s\n" "$ROWS" | wc -l | tr -d ' ')"
echo "  found $ROW_COUNT row(s) to evaluate"
echo

# ----------------------------------------------------------------------------
# Step 2: resolve each + decide UPDATE vs DELETE
# ----------------------------------------------------------------------------
echo "[2/3] Resolving each follow.it proxy via HEAD + ?q= extraction..."
echo

UPDATED=0
DELETED=0
SKIPPED=0

while IFS='|' read -r row_id row_url; do
  [[ -z "$row_id" ]] && continue
  echo "  --- id=$row_id ---"
  echo "    before: $row_url"

  canonical="$(unwrap_followit "$row_url")"
  if [[ -z "$canonical" ]]; then
    echo "    SKIPPED — could not unwrap (no 302 Location or no ?q= param)"
    SKIPPED=$((SKIPPED + 1))
    sleep "$RATE_LIMIT_SECONDS"
    continue
  fi
  echo "    after:  $canonical"

  exists="$(canonical_exists "$canonical")"
  if [[ "$exists" == "1" ]]; then
    # Canonical already present as a separate row — delete this proxy row
    # to keep the (source_platform, source_url) unique constraint satisfied.
    echo "    ACTION: DELETE (canonical already present in another row)"
    if [[ "$APPLY" -eq 1 ]]; then
      printf "%s\n" "DELETE FROM outreach_items WHERE id=${row_id};" | run_sql >/dev/null
    else
      echo "      (dry-run) DELETE FROM outreach_items WHERE id=${row_id};"
    fi
    DELETED=$((DELETED + 1))
  else
    echo "    ACTION: UPDATE"
    if [[ "$APPLY" -eq 1 ]]; then
      esc="${canonical//\'/\'\'}"
      printf "%s\n" \
        "UPDATE outreach_items SET source_url='${esc}' WHERE id=${row_id};" \
        | run_sql >/dev/null
    else
      echo "      (dry-run) UPDATE outreach_items SET source_url=<canonical> WHERE id=${row_id};"
    fi
    UPDATED=$((UPDATED + 1))
  fi
  sleep "$RATE_LIMIT_SECONDS"
done <<< "$ROWS"

# ----------------------------------------------------------------------------
# Step 3: summary
# ----------------------------------------------------------------------------
echo
echo "[3/3] Summary ($MODE_LABEL)"
echo "  evaluated: $ROW_COUNT"
echo "  updated:   $UPDATED"
echo "  deleted:   $DELETED"
echo "  skipped:   $SKIPPED"

if [[ "$APPLY" -eq 0 ]]; then
  echo
  echo "  DRY-RUN: no rows were modified. Re-run with --apply to commit."
fi
