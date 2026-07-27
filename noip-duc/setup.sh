#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent setup for the No-IP Dynamic Update Client on the proxy LXC (PCT 100).
#
# Run as root INSIDE the container. Assumes these have already been placed by the host:
#   /etc/systemd/system/noip-duc.service.d/10-cortech.conf   (pct push, from this dir)
#   /etc/default/noip-duc                                    (see .env.example)
#
# The service unit itself comes from the .deb (/lib/systemd/system/noip-duc.service)
# and is already correct; we only layer the drop-in on top.

export DEBIAN_FRONTEND=noninteractive

# Both overridable only so test-preflight.sh can exercise the preflight without
# touching real paths — and so its positive case reliably stops at the drop-in
# check instead of falling through to apt-get on a host that already has one.
# In the container these are always the real paths.
ENV_FILE="${NOIP_ENV_FILE:-/etc/default/noip-duc}"
DROPIN="${NOIP_DROPIN:-/etc/systemd/system/noip-duc.service.d/10-cortech.conf}"

# --- preflight -------------------------------------------------------------
# A DUC with empty credentials doesn't fail loudly, it loops on auth errors.
# Refuse to enable the service until the env file has real values — a file copied
# straight from .env.example is non-empty (NOIP_HOSTNAMES is prefilled) but has
# blank NOIP_USERNAME/NOIP_PASSWORD, so an -s test alone lets that through.
if [ ! -s "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE is missing or empty." >&2
  echo "       Populate it from noip-duc/.env.example (DDNS Key user/pass, mode 0600) first." >&2
  exit 1
fi
missing=()
for key in NOIP_USERNAME NOIP_PASSWORD NOIP_HOSTNAMES; do
  # Require at least one non-whitespace character after the '=' — catches both
  # `KEY=` and `KEY=   `. Greps rather than sourcing, so a malformed file can't
  # execute anything as root.
  grep -qE "^${key}=[^[:space:]]" "$ENV_FILE" || missing+=("$key")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: $ENV_FILE has no value for: ${missing[*]}" >&2
  echo "       noip-duc would start and loop on auth failures. Fill them in" >&2
  echo "       (DDNS Key credentials live in Infisical dev) and re-run." >&2
  exit 1
fi
if [ ! -f "$DROPIN" ]; then
  echo "ERROR: drop-in $DROPIN not found" >&2
  echo "       — pct push it first (see noip-duc/README.md)." >&2
  exit 1
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# An earlier revision shipped a full unit override here. It shadowed the packaged
# unit for two directives that are now a drop-in; remove it if it's still around.
if [ -f /etc/systemd/system/noip-duc.service ]; then
  echo "==> removing obsolete full-unit override /etc/systemd/system/noip-duc.service"
  rm -f /etc/systemd/system/noip-duc.service
fi

# --- install ---------------------------------------------------------------
if ! command -v noip-duc >/dev/null 2>&1; then
  echo "==> installing noip-duc"
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # ponytail: unpinned. Only https://www.noip.com/download/linux/latest resolves —
  # No-IP publishes no versioned URL (both .../noip-duc_3.3.0.tar.gz and .../3.3.0
  # return 404), so there is nothing to pin to. The `noip-duc --version` echo below
  # records what actually landed. Pin here the day No-IP ships a versioned path.
  curl -fsSL -o "$tmp/noip-duc.tar.gz" https://www.noip.com/download/linux/latest
  tar xzf "$tmp/noip-duc.tar.gz" -C "$tmp"

  deb="$(find "$tmp" -type f -name 'noip-duc_*_amd64.deb' -print -quit)"
  [ -n "$deb" ] || { echo "ERROR: no amd64 .deb in the No-IP tarball" >&2; exit 1; }
  apt-get install -y --no-install-recommends "$deb"
fi

echo "==> installed: $(noip-duc --version 2>&1 | head -1) at $(command -v noip-duc)"

# --- enable ----------------------------------------------------------------
echo "==> enabling noip-duc.service"
systemctl daemon-reload
systemctl enable --now noip-duc
systemctl restart noip-duc

echo
echo "Setup complete. Verify the record now matches the WAN IP (run on the Proxmox master):"
# shellcheck disable=SC2016  # printing a command for the operator to copy; must not expand here
echo '  a=$(dig +short corbello.ddns.net @1.1.1.1); b=$(curl -s https://api.ipify.org)'
# shellcheck disable=SC2016
echo '  echo "ddns=$a wan=$b"; [ "$a" = "$b" ] && echo MATCH || echo STALE'
