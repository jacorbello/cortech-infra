#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent setup for the No-IP Dynamic Update Client on the proxy LXC (PCT 100).
#
# Run as root INSIDE the container. Assumes these have already been placed by the host:
#   /etc/systemd/system/noip-duc.service   (pct push from noip-duc/noip-duc.service)
#   /etc/default/noip-duc                  (populated on the guest — see .env.example)

export DEBIAN_FRONTEND=noninteractive

# --- preflight -------------------------------------------------------------
# A DUC with empty credentials doesn't fail loudly, it loops on auth errors.
# Refuse to enable the service until the env file actually has content.
if [ ! -s /etc/default/noip-duc ]; then
  echo "ERROR: /etc/default/noip-duc is missing or empty." >&2
  echo "       Populate it from noip-duc/.env.example (DDNS Key user/pass, mode 0600) first." >&2
  exit 1
fi
if [ ! -f /etc/systemd/system/noip-duc.service ]; then
  echo "ERROR: /etc/systemd/system/noip-duc.service not found — pct push it first." >&2
  exit 1
fi
chown root:root /etc/default/noip-duc
chmod 0600 /etc/default/noip-duc

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

# The unit hardcodes /usr/bin/noip-duc; fail now rather than at first boot if the
# package ever moves the binary.
if [ ! -x /usr/bin/noip-duc ]; then
  echo "ERROR: /usr/bin/noip-duc not found (dpkg -L noip-duc) — fix ExecStart in the unit." >&2
  exit 1
fi

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
