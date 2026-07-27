#!/usr/bin/env bash
set -Eeuo pipefail

# Restarts noip-duc when the DDNS record has drifted from the real WAN IP.
#
# Why this exists: noip-duc does NOT exit when its IP lookups fail — it escalates
# an internal backoff up to "retrying after 30m" while systemd still reports the
# unit `active`. So Restart=on-failure never fires, and a WAN change during a DNS
# blip leaves corbello.ddns.net stale for up to half an hour. A restart clears the
# backoff and the update lands in under a second. Observed 2026-07-27.
#
# ponytail: a watchdog, not a second poller. noip-duc still owns the 5-minute
# polling; this only notices it has silently given up. If upstream ever adds a
# backoff cap (there is no such flag as of 3.3.0), delete this whole unit.

HOST="${NOIP_WATCH_HOST:-corbello.ddns.net}"
# Authoritative for ddns.net. Deliberately NOT a public resolver: caches lag the
# TTL, which would trigger spurious restarts on a perfectly current record.
NS="${NOIP_WATCH_NS:-nf1.no-ip.com}"
# Don't restart a service that only just started — without this, a genuinely broken
# credential would get a pointless restart every time the timer fires.
MIN_AGE="${NOIP_WATCH_MIN_AGE:-600}"
DRY_RUN=0
# An `if`, not `[ … ] && DRY_RUN=1`: under `set -e` a failing AND-list at top level
# is a classic way to exit a script silently. It happens to survive here, but the
# production path runs without --dry-run, so this is not a place to rely on nuance.
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

# Seams for test-watchdog.sh; unset in production, where both are fetched live.
# Tested with ${VAR+x} (set-ness) rather than -n (non-emptiness): an injected empty
# string is how the test simulates a FAILED lookup, and a `${VAR-}` default would
# fall straight through to a live dig/curl instead — making the test depend on
# whether the host happens to have dig and internet.
if [ -n "${NOIP_WATCH_REC+x}" ]; then rec="$NOIP_WATCH_REC"
else rec=$(dig +short "$HOST" "@$NS" 2>/dev/null | head -1 || true); fi
if [ -n "${NOIP_WATCH_WAN+x}" ]; then wan="$NOIP_WATCH_WAN"
else wan=$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true); fi

# A lookup we couldn't complete says nothing about the record. Restarting on our
# own transient failure is how a watchdog turns one blip into a restart loop.
if [ -z "$rec" ] || [ -z "$wan" ]; then
  echo "watchdog: inconclusive (record='${rec:-?}' wan='${wan:-?}') — no action"
  exit 0
fi

if [ "$rec" = "$wan" ]; then
  echo "watchdog: ok, $HOST == $wan"
  exit 0
fi

if [ -n "${NOIP_WATCH_AGE+x}" ]; then age="$NOIP_WATCH_AGE"
else
  started=$(systemctl show noip-duc -p ActiveEnterTimestamp --value 2>/dev/null || true)
  started_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
  if [ "$started_epoch" -gt 0 ]; then age=$(( $(date +%s) - started_epoch )); else age=$MIN_AGE; fi
fi

if [ "$age" -lt "$MIN_AGE" ]; then
  echo "watchdog: $HOST=$rec but wan=$wan; noip-duc restarted ${age}s ago (<${MIN_AGE}s) — waiting"
  exit 0
fi

echo "watchdog: DRIFT — $HOST=$rec but wan=$wan; restarting noip-duc"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "watchdog: dry-run, not restarting"
  exit 0
fi
systemctl restart noip-duc
