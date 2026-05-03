#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent setup for the timemachine LXC.
# Assumes /etc/samba/smb.conf and /etc/avahi/services/timemachine.service
# have already been pushed in via `pct push` from the host.

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  samba \
  avahi-daemon \
  libnss-mdns \
  acl \
  attr

# Backup user — no shell, no home, password set via smbpasswd later.
if ! id -u tm >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin tm
fi

# Backup directory.
install -d -o tm -g tm -m 0700 /srv/timemachine

# Confirm xattr / ACL support on the mount (vfs_fruit needs it).
touch /srv/timemachine/.xattr-test
if ! setfattr -n user.test -v 1 /srv/timemachine/.xattr-test 2>/dev/null; then
  echo "ERROR: user xattrs not supported on /srv/timemachine — vfs_fruit will fail" >&2
  rm -f /srv/timemachine/.xattr-test
  exit 1
fi
rm -f /srv/timemachine/.xattr-test

testparm -s >/dev/null

systemctl enable --now smbd nmbd avahi-daemon
systemctl restart smbd nmbd avahi-daemon

echo
echo "Setup complete. Set the SMB password for user 'tm' with:"
echo "  smbpasswd -a tm"
