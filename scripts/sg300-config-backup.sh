#!/usr/bin/env bash
# Capture the SG300's running-config before a firmware upgrade.
#
# The full config contains the local user's password hash and the SNMP community
# string, so it is written OUTSIDE the repo. A redacted copy is written next to it
# for committing / diffing after the upgrade.
#
# Usage:  scripts/sg300-config-backup.sh [output-dir]
#         (must run from a real terminal — the switch prompts for a password)
set -Eeuo pipefail

OUT_DIR="${1:-$HOME/cortech-backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FULL="$OUT_DIR/sg300-running-config-$STAMP.txt"
REDACTED="$OUT_DIR/sg300-running-config-$STAMP.redacted.txt"

command -v sshpass >/dev/null || { echo "need sshpass: sudo apt install sshpass" >&2; exit 1; }
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

read -rsp "SG300 password (Infisical homelab/CISCO_SG300_PASSWORD): " SSHPASS
echo
export SSHPASS

# -tt forces a PTY: the switch has no PTY-less login, and `terminal datadump`
# disables the pager that would otherwise stall at --More--.
sshpass -e ssh -tt sg300 <<'CMDS' >"$FULL" 2>&1
terminal datadump
show version
show bootvar
show running-config
exit
CMDS

chmod 600 "$FULL"

# Redact anything that authenticates: password hashes and SNMP communities.
sed -E \
  -e 's/(password encrypted )[^ ]+/\1<REDACTED>/' \
  -e 's/(snmp-server community )[^ ]+/\1<REDACTED>/' \
  "$FULL" >"$REDACTED"

echo "full     : $FULL  (mode 600, contains secrets — do NOT commit)"
echo "redacted : $REDACTED"
echo

# Fail loudly rather than hand back a file that looks sanitised but isn't.
if grep -qE 'password encrypted [^<]|snmp-server community [^<]' "$REDACTED"; then
  echo "redaction: FAILED — secrets still present in $REDACTED" >&2
  exit 1
fi
echo "redaction: OK — no unredacted password hash or community string remains"
