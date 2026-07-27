#!/usr/bin/env bash
set -Eeuo pipefail

# Checks noip-duc-watchdog.sh's decision logic. Always --dry-run, and every case
# injects the record/WAN/age, so nothing here queries DNS, touches the network, or
# restarts a service — safe on PCT 100 itself.
#
# Run:  ./noip-duc/test-watchdog.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$HERE/noip-duc-watchdog.sh"
fails=0

# expect <name> <record> <wan> <age> <wanted-substring>
expect() {
  local name="$1" rec="$2" wan="$3" age="$4" want="$5" out
  out=$(NOIP_WATCH_REC="$rec" NOIP_WATCH_WAN="$wan" NOIP_WATCH_AGE="$age" \
        bash "$WD" --dry-run 2>&1) || true
  if printf '%s' "$out" | grep -qF "$want"; then
    echo "ok: $name"
  else
    echo "FAIL: $name"
    echo "      wanted: $want"
    echo "      got:    $(printf '%s' "$out" | tr '\n' ' ')"
    fails=$((fails + 1))
  fi
}

# Record matches the WAN — the normal case. Must not restart.
expect "record matches WAN" 24.28.96.15 24.28.96.15 9999 "ok, corbello.ddns.net == 24.28.96.15"

# The bug this exists for: WAN moved, record didn't, daemon has been "active" for ages.
expect "drift, service old" 24.28.103.164 24.28.96.15 9999 "DRIFT"

# Just restarted — restarting again every 10 min would be a loop on a revoked key.
expect "drift, just restarted" 24.28.103.164 24.28.96.15 30 "restarted 30s ago"

# Our own lookup failed. Says nothing about the record; must NOT restart.
expect "record lookup failed" "" 24.28.96.15 9999 "inconclusive"
expect "wan lookup failed" 24.28.103.164 "" 9999 "inconclusive"
expect "both failed" "" "" 9999 "inconclusive"

# Boundary: exactly at MIN_AGE counts as old enough to act.
expect "age exactly at threshold" 24.28.103.164 24.28.96.15 600 "DRIFT"

# And dry-run must really not restart.
out=$(NOIP_WATCH_REC=1.1.1.1 NOIP_WATCH_WAN=2.2.2.2 NOIP_WATCH_AGE=9999 \
      bash "$WD" --dry-run 2>&1) || true
if printf '%s' "$out" | grep -qF "dry-run, not restarting"; then
  echo "ok: dry-run stops short of the restart"
else
  echo "FAIL: dry-run did not report stopping short"; fails=$((fails + 1))
fi

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
