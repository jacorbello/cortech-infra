#!/usr/bin/env bash
# Capture the SG300's running-config before a firmware upgrade.
#
# The full config contains the local user's password hash and the SNMP community
# string, so it is written OUTSIDE the repo. A redacted copy is written next to it
# for committing / diffing after the upgrade.
#
# Usage:  scripts/sg300-config-backup.sh [output-dir]
#         (must run from a real terminal — it prompts for the switch password)
set -Eeuo pipefail

OUT_DIR="${1:-$HOME/cortech-backups}"
SW_USER="${SG300_USER:-cisco}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FULL="$OUT_DIR/sg300-running-config-$STAMP.txt"
REDACTED="$OUT_DIR/sg300-running-config-$STAMP.redacted.txt"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

read -rsp "SG300 password (Infisical homelab/CISCO_SG300_PASSWORD): " SW_PASS
echo

# This switch does NOT authenticate at the SSH layer — SSH connects without a
# password and the *device* then prompts "User Name:" / "Password:". So sshpass is
# useless here; the credentials must be the first two lines written to the shell,
# ahead of any command. Getting this wrong feeds "terminal datadump" into the
# password field and burns three login attempts.
#
# -tt forces a PTY (no PTY-less login exists) and the sleeps let each prompt
# render before the next line is sent — this device does not buffer typeahead.
{
  sleep 2; printf '%s\r' "$SW_USER"
  sleep 2; printf '%s\r' "$SW_PASS"
  sleep 3; printf 'terminal datadump\r'   # disable the --More-- pager
  sleep 1; printf 'show version\r'
  sleep 2; printf 'show bootvar\r'
  sleep 2; printf 'show running-config\r'
  sleep 4; printf 'exit\r'
  sleep 2
} | ssh -tt sg300 >"$FULL" 2>&1 || true   # ssh exits non-zero on the remote hangup

chmod 600 "$FULL"

if ! grep -q 'show running-config' "$FULL"; then
  echo "capture FAILED — no command echo found in $FULL" >&2
  echo "check the file; a repeated 'User Name:Password:' means login did not take." >&2
  exit 1
fi
if grep -qi 'authentication failed' "$FULL"; then
  echo "capture FAILED — authentication rejected. Wrong password?" >&2
  exit 1
fi

# Redact anything that authenticates: password hashes and SNMP communities.
sed -E \
  -e 's/(password encrypted )[^ ]+/\1<REDACTED>/' \
  -e 's/(snmp-server community )[^ ]+/\1<REDACTED>/' \
  "$FULL" >"$REDACTED"

# Fail loudly rather than hand back a file that looks sanitised but isn't.
if grep -qE 'password encrypted [^<]|snmp-server community [^<]' "$REDACTED"; then
  echo "redaction FAILED — secrets still present in $REDACTED" >&2
  exit 1
fi

echo "full     : $FULL  (mode 600, contains secrets — do NOT commit)"
echo "redacted : $REDACTED"
echo "redaction: OK — no unredacted password hash or community string remains"
