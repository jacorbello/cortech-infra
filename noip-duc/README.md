# noip-duc — Dynamic DNS for `corbello.ddns.net` (on PCT 100)

All public hostnames (`*.corbello.io`, `plotlens.ai`, …) are CNAMEs to `corbello.ddns.net`
at Namecheap. When the ISP hands out a new WAN IP and nothing updates that record, every
public service goes dark. Before this existed there was no updater at all — the record was
corrected by hand whenever someone noticed something was down.

This runs the No-IP Dynamic Update Client as a systemd service on the proxy LXC, so the
record follows the WAN IP automatically.

## What's here

| File | Purpose |
|------|---------|
| `setup.sh` | Idempotent guest provisioning (run as root inside PCT 100) |
| `noip-duc.service.d/10-cortech.conf` | systemd drop-in — the only two deltas from the packaged unit |
| `.env.example` | Template for `/etc/default/noip-duc` (DDNS Key credentials) |
| `test-preflight.sh` | Checks the credential preflight. Runs anywhere — no container, root, or network |
| `noip-duc-watchdog.sh` | Restarts noip-duc when the record has drifted from the WAN IP |
| `noip-duc-watchdog.{service,timer}` | Runs the watchdog every 10 min |
| `test-watchdog.sh` | Checks the watchdog's decision logic. Also runs anywhere |

**There is no unit file here.** The `.deb` ships
`/lib/systemd/system/noip-duc.service`, and it is already correct — it reads
`EnvironmentFile=/etc/default/noip-duc`, runs `/usr/bin/noip-duc`, `Type=simple`,
`Restart=on-failure`. A drop-in adds `network-online.target` ordering and
`RestartSec=30` without shadowing the package, so an upstream fix still reaches us.

`setup.sh` refuses to enable the service unless `NOIP_USERNAME`, `NOIP_PASSWORD` and
`NOIP_HOSTNAMES` all have real values. A DUC with blank credentials starts happily and
loops on auth failures while the record rots — and a file copied straight from
`.env.example` is *non-empty* (`NOIP_HOSTNAMES` is prefilled), so testing the file rather
than the values would let exactly that through. `./noip-duc/test-preflight.sh` covers it.

## The watchdog, and why it exists

`noip-duc` does **not** exit when its IP lookups fail. It escalates an internal
backoff — up to `retrying after 30m` — while systemd still reports the unit
`active`. So `Restart=on-failure` never fires, and a WAN change that lands during a
DNS blip leaves the record stale for up to half an hour. Seen for real on
2026-07-27: the WAN moved, LXC 100 briefly couldn't resolve
`ip1.dynupdate.no-ip.com`, and the DUC sat in a 30-minute backoff reporting healthy.
A restart fixed it in under a second.

There is no flag to cap that backoff (checked `noip-duc --help`, 3.3.0), so
`noip-duc-watchdog.timer` fires every 10 minutes and compares the **authoritative**
record against the live WAN IP, restarting `noip-duc` only on a mismatch. It caps
staleness at ~10 min. Deliberately narrow:

- Queries `@nf1.no-ip.com`, never a public resolver — caches lag the TTL and would
  cause spurious restarts on a perfectly current record.
- If either lookup fails it does **nothing**. An inconclusive check says nothing
  about the record, and restarting on our own transient failure is how a watchdog
  turns one blip into a restart loop.
- Won't restart a service that started less than 10 min ago, so a genuinely broken
  credential gets one restart, not one every 10 minutes forever.

This is a watchdog, not the second scheduler rejected under **Notes** — `noip-duc`
still owns the 5-minute polling. If upstream ever caps the backoff, delete the unit.

## Dependencies installed by setup.sh

- `ca-certificates`, `curl`
- `noip-duc` — from No-IP's `linux/latest` tarball (`noip-duc_*_amd64.deb` → `/usr/bin/noip-duc`)

## Why PCT 100

The proxy LXC is already the target of the only two TCP router forwards (80/443 →
`192.168.1.100`), is `onboot: 1` and tagged `critical`. The coupling is deliberate: if the
proxy is down, an accurate DNS record buys nothing anyway. Cost is a ~5 MB Rust binary in
a 512 MB container.

## Deploy

On the cortech master, with this repo's `noip-duc/` available:

```bash
# 1. Push the drop-in and the setup script into the container
#    (pct push does not create directories — mkdir first)
pct exec 100 -- mkdir -p /etc/systemd/system/noip-duc.service.d
pct push 100 noip-duc/noip-duc.service.d/10-cortech.conf \
             /etc/systemd/system/noip-duc.service.d/10-cortech.conf
pct push 100 noip-duc/setup.sh /root/noip-duc-setup.sh
for f in noip-duc-watchdog.sh noip-duc-watchdog.service noip-duc-watchdog.timer; do
  pct push 100 "noip-duc/$f" "/root/$f"
done

# 2. Create the secret ON THE GUEST (values from Infisical dev — see .env.example)
pct exec 100 -- install -m 0600 -o root -g root /dev/null /etc/default/noip-duc
pct exec 100 -- tee /etc/default/noip-duc >/dev/null <<'EOF'
NOIP_USERNAME=<ddns-key-user>
NOIP_PASSWORD=<ddns-key-pass>
NOIP_HOSTNAMES=all.ddnskey.com
EOF

# 3. Install + enable
pct exec 100 -- bash /root/noip-duc-setup.sh
```

The first start is what corrects a stale record — there is no separate manual update step.

## One-time steps (not scriptable)

1. In the No-IP portal: **Dynamic DNS → DDNS Keys → Create DDNS Key**, attach
   `corbello.ddns.net` to it. Use a DDNS Key, not the account login — a key can only
   update DNS, so a leak of `/etc/default/noip-duc` is not account takeover.
2. Store the key username and password in Infisical (`dev`).

## Ops

```bash
# Status / logs
pct exec 100 -- systemctl status noip-duc --no-pager
pct exec 100 -- journalctl -u noip-duc -n 50 --no-pager

# Force a re-check
pct exec 100 -- systemctl restart noip-duc

# Watchdog: when it last ran, what it decided, and when it fires next
pct exec 100 -- systemctl list-timers noip-duc-watchdog.timer --no-pager
pct exec 100 -- journalctl -u noip-duc-watchdog -n 20 --no-pager

# Ask the watchdog what it would do, without letting it act
pct exec 100 -- /usr/local/sbin/noip-duc-watchdog --dry-run
```

**Is the record correct?** The real check — run on the Proxmox master (the laptop has no `dig`):

```bash
a=$(dig +short corbello.ddns.net @1.1.1.1); b=$(curl -s https://api.ipify.org)
echo "ddns=$a wan=$b"; [ "$a" = "$b" ] && echo MATCH || echo STALE
```

**If it says STALE:**

0. First: has it been stale under 10 minutes? The watchdog is probably about to fix
   it. `systemctl list-timers noip-duc-watchdog.timer` shows when it next fires.
1. `journalctl -u noip-duc` — `Failed to get IP ... retrying after 30m` means the
   internal backoff; `systemctl restart noip-duc` clears it immediately. Auth errors
   instead mean the DDNS Key was rotated or revoked in the portal — re-issue it,
   update `/etc/default/noip-duc`, restart.
2. Still stale with clean logs? The hostname may not be attached to the key's group, so
   `all.ddnskey.com` doesn't cover it. Check the portal.
3. Resolver cache — this is the likely answer, and it bites hard. Public resolvers cache
   the old address for the TTL, so `@1.1.1.1` can report a stale IP long after No-IP has
   the right one. Ask No-IP's authoritative nameservers instead:
   ```bash
   dig +short corbello.ddns.net @nf1.no-ip.com   # authoritative for ddns.net
   ```
   If that matches the WAN IP, the record is fine and you are looking at a cache.
   (`corbello.io` is at Namecheap, but `corbello.ddns.net` is not — `dns1.registrar-servers.com`
   is the wrong nameserver to ask about it.)

**After the WAN IP moves**, `certbot` renewals that failed while DNS was stale need a
manual pass: `pct exec 100 -- certbot renew --nginx`.

## Notes

- **No polling timer.** noip-duc daemonizes and polls on its own
  `NOIP_CHECK_INTERVAL` (default 5m); a timer duplicating that would be a second
  scheduler doing the same job. The one timer here is a *watchdog* — it doesn't poll
  the WAN on noip-duc's behalf, it notices when noip-duc has silently stopped doing
  so. See **The watchdog** above.
- **Version is not pinned.** No-IP publishes only `download/linux/latest`; versioned URLs
  404. `setup.sh` logs `noip-duc --version` so the journal records what landed.
- **`Restart=on-failure`, not `always`** (from the packaged unit). A clean exit is the
  binary's own decision; restart-looping against No-IP looks like an abusive client.
- The router's built-in DDNS client was the alternative — rejected so the config is
  tracked in this repo rather than in router flash.
