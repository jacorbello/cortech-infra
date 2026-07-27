#!/usr/bin/env bash
set -Eeuo pipefail

# Checks setup.sh's credential preflight — the guard that stops a DUC with blank
# credentials from being enabled, where it would silently loop on auth failures.
#
# Safe to run anywhere, including on PCT 100 itself: every case points NOIP_DROPIN
# at a path that does not exist, so setup.sh always exits at the drop-in check and
# can never reach apt-get, `systemctl enable --now`, or a service restart. Without
# that, the positive case would sail past both preflights on any host where the
# real drop-in is already installed.
#
# Run:  ./noip-duc/test-preflight.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP="$HERE/setup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

# Deliberately absent — the backstop that keeps setup.sh from doing real work here.
ABSENT_DROPIN="$tmp/no-such-dropin.conf"

# Asserts setup.sh rejects $2 (an env-file body) with a message matching $3.
expect_reject() {
  local name="$1" body="$2" want="$3" out rc=0
  printf '%s' "$body" >"$tmp/env"
  out=$(NOIP_ENV_FILE="$tmp/env" NOIP_DROPIN="$ABSENT_DROPIN" bash "$SETUP" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $name — expected a non-zero exit, got 0"; fails=$((fails + 1)); return
  fi
  if ! printf '%s' "$out" | grep -qF "$want"; then
    echo "FAIL: $name — exited $rc but not for the expected reason"
    echo "      wanted substring: $want"
    echo "      got: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    fails=$((fails + 1)); return
  fi
  echo "ok: $name"
}

# The regression Bugbot caught: .env.example copied verbatim. Non-empty file
# (NOIP_HOSTNAMES is prefilled), so an -s test alone would wave it through.
expect_reject "template copied verbatim" \
  'NOIP_USERNAME=
NOIP_PASSWORD=
NOIP_HOSTNAMES=all.ddnskey.com
' "has no value for: NOIP_USERNAME NOIP_PASSWORD"

expect_reject "password left blank" \
  'NOIP_USERNAME=keyuser
NOIP_PASSWORD=
NOIP_HOSTNAMES=all.ddnskey.com
' "has no value for: NOIP_PASSWORD"

# Whitespace is not a value — `KEY=   ` must not satisfy the check. Built with
# printf so the trailing spaces survive (an editor would strip them from a literal).
expect_reject "whitespace-only value" \
  "$(printf 'NOIP_USERNAME=keyuser\nNOIP_PASSWORD=   \nNOIP_HOSTNAMES=all.ddnskey.com\n')" \
  "has no value for: NOIP_PASSWORD"

expect_reject "hostnames missing entirely" \
  'NOIP_USERNAME=keyuser
NOIP_PASSWORD=keypass
' "has no value for: NOIP_HOSTNAMES"

expect_reject "empty file" '' "is missing or empty"

# Fully-populated env must get PAST the credential preflight. Asserting on the
# drop-in error specifically proves both that it passed AND exactly where it
# stopped — a bare "no rejection message" check would also pass if the script had
# run all the way through apt-get and systemctl.
printf 'NOIP_USERNAME=keyuser\nNOIP_PASSWORD=keypass\nNOIP_HOSTNAMES=all.ddnskey.com\n' >"$tmp/env"
rc=0
out=$(NOIP_ENV_FILE="$tmp/env" NOIP_DROPIN="$ABSENT_DROPIN" bash "$SETUP" 2>&1) || rc=$?
if printf '%s' "$out" | grep -qF "has no value for"; then
  echo "FAIL: valid credentials — preflight rejected a fully-populated env file"
  fails=$((fails + 1))
elif ! printf '%s' "$out" | grep -qF "drop-in $ABSENT_DROPIN not found"; then
  echo "FAIL: valid credentials — expected to stop at the drop-in check, got:"
  echo "      $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fails=$((fails + 1))
else
  echo "ok: valid credentials pass the credential preflight, then stop at the drop-in check"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) FAILED"
  exit 1
fi
echo "all checks passed"
