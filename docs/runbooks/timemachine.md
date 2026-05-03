# Time Machine (LXC 125)

Samba SMB target for macOS Time Machine backups, served from a dedicated Proxmox LXC.

## Topology

| Field | Value |
|---|---|
| PCT ID | 125 |
| Hostname | `timemachine` |
| Host | `cortech` (192.168.1.52) |
| IP | `192.168.1.151/24` |
| Template | `debian-13-standard` (Samba 4.22.x) |
| Resources | 2 vCPU, 1 GiB RAM, 8 GiB rootfs, 1 TiB mp0 on `local-lvm` |
| Share path | `/srv/timemachine` |
| Quota | `fruit:time machine max size = 950G` |
| User | `tm` (system user, SMB-only) |

Source files in repo:
- `pct/125-timemachine.conf` — PCT definition
- `timemachine/smb.conf` — Samba config (vfs_fruit + SMB3)
- `timemachine/timemachine.service` — Avahi mDNS advertisement (`_smb._tcp` + `_adisk._tcp`)
- `timemachine/setup.sh` — idempotent provisioning script

## Connecting from macOS

1. Finder → ⌘K → `smb://192.168.1.151/TimeMachine`
2. Auth: username `tm`, password set via `smbpasswd`
3. System Settings → General → Time Machine → **Add Backup Disk** → pick TimeMachine
4. The host also auto-advertises via Bonjour (Avahi `_adisk._tcp`), so the disk appears in System Settings without needing to mount it first

## Operations

### Set / change SMB password

```bash
ssh root@192.168.1.52 "pct exec 125 -- smbpasswd -a tm"   # initial set
ssh root@192.168.1.52 "pct exec 125 -- smbpasswd tm"      # subsequent change
```

### Reload config after editing `timemachine/smb.conf`

```bash
scp timemachine/smb.conf root@192.168.1.52:/tmp/smb.conf
ssh root@192.168.1.52 "pct push 125 /tmp/smb.conf /etc/samba/smb.conf && pct exec 125 -- systemctl reload smbd && rm /tmp/smb.conf"
```

### Resize the backup volume

```bash
ssh root@192.168.1.52 "pct resize 125 mp0 +500G"     # grow by 500 GiB (live, online resize)
# Then bump fruit:time machine max size in smb.conf and reload
```

LVM-thin only allows growth, never shrink.

### Re-run setup (idempotent)

```bash
scp timemachine/setup.sh root@192.168.1.52:/tmp/setup.sh
ssh root@192.168.1.52 "pct push 125 /tmp/setup.sh /root/setup.sh --perms 0755 && pct exec 125 -- bash /root/setup.sh"
```

### Service health

```bash
ssh root@192.168.1.52 "pct exec 125 -- systemctl is-active smbd nmbd avahi-daemon"
ssh root@192.168.1.52 "pct exec 125 -- testparm -s"
```

## Troubleshooting

**"The backup disk image could not be created"** — almost always xattr support. Verify on the LXC:
```bash
pct exec 125 -- bash -c 'touch /srv/timemachine/.t && setfattr -n user.test -v 1 /srv/timemachine/.t && rm /srv/timemachine/.t && echo OK'
```

**"Disk Not Recommended for Backups"** — Apple's heuristic wants ≥ 2× the Mac's data size. Soft warning only; backups still work and prune oldest snapshots when full. Resize the volume + bump `fruit:time machine max size` if you want it gone.

**Mac doesn't see it in Finder sidebar** — check Avahi:
```bash
pct exec 125 -- systemctl status avahi-daemon
pct exec 125 -- avahi-browse -a -t | grep -i timemachine
```

## Notes

- Samba 4.22.x (Debian 13) is required for the macOS Sequoia regression fix. Earlier 4.21.x has known Time Machine issues.
- `vfs objects` line **must** be repeated in the share section — per-share `vfs objects` overrides the global list, not supplements it.
- `aio_pthread` last in the vfs stack prevents backup scans from stalling on large directories.
- `fruit:posix_rename = yes` is still needed for 4.22.x; Samba 4.23 will drop the requirement.
- Avahi handles all mDNS; Samba's built-in `multicast dns register` is disabled in `smb.conf` to avoid double-advertising.
- Host-level `smbd`/`nmbd` are intentionally NOT installed — all SMB lives in this LXC. The host's `samba` server packages were purged on 2026-05-03.
