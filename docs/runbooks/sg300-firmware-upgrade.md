# Runbook: SG300-52 firmware upgrade (1.1.2.0 → 1.4.11.5)

**Status: planned, not executed.** Nothing in here has been run. See
`docs/switch-sg300.md` for the switch itself.

## Why this is not a one-step upgrade

Cisco requires stepped upgrades from firmware older than 1.3.5. The direct jump
from 1.1.2.0 to 1.4.x is unsupported and fails.

| Stage | From → To | Reboot | Rollback |
|-------|-----------|--------|----------|
| 1 | firmware 1.1.2.0 → **1.3.7.18** | yes | boot inactive image |
| 2 | boot code → **1.3.5.06** | yes | **none — see below** |
| 3 | firmware 1.3.7.18 → **1.4.11.5** | yes | boot inactive image |

Total: three LAN outages, 45–90 minutes end to end including verification.

### The one genuinely dangerous step

The switch stores **two firmware images** (active and inactive), so a bad firmware
flash is recoverable — boot the other image. **Boot code has no second slot.** An
interrupted or corrupt boot-code flash bricks the switch, and the only recovery is
the serial console via the boot menu.

Do not start stage 2 without console access physically in hand.

## Blast radius

Every host in the port map loses link on each reboot — all five Proxmox nodes plus
the router uplink, simultaneously:

| Port | Host |
|------|------|
| gi1 / gi2 / gi44 / gi47 / gi48 | cortech-node1 / master / node2 / node5 / node3-gpu |
| gi3 | unidentified device at 192.168.1.49 |
| gi50 | router uplink — all WAN and household traffic |

All **7** live ports drop, not just the six known hosts.

Consequences per reboot:

- K3s nodes mark each other `NotReady`; etcd loses quorum for the duration
- All public ingress via proxy LXC 100 is down
- **NFS mounts may hang on k3s-wrk-3.** In past network interruptions a hung NFS
  mount on this node did not recover on its own and cleared only by resetting the
  VM from the Proxmox master:
  ```
  ssh root@192.168.1.52 "qm reset 206"
  ```
- **Guests do not reliably auto-start after an unclean stop.** `onboot` is unset on
  several guests, so after a hard stop they must be started manually in dependency
  order from the master — control plane (200-202) first, then proxy LXC 100, then
  Postgres (114) and Redis, then the rest:
  ```
  ssh root@192.168.1.52 "qm start 200; qm start 201; qm start 202"
  ssh root@192.168.1.52 "pct start 100; pct start 114; pct start 116"
  ```

## Prerequisites

- [x] **Working serial console — SATISFIED (2026-08-05), see below.** Verified by
      reading a real login prompt off the port. Re-verify immediately before the
      window; owning a cable is not the same as having a working console.
- [ ] Physical access to the switch.
- [ ] Firmware images downloaded and checksummed **before** the window:
      `1.3.7.18`, boot code `1.3.5.06`, `1.4.11.5`. Requires a Cisco.com account;
      the SG300 line is effectively end-of-support, so confirm the downloads still
      resolve before scheduling.
- [ ] `copy running-config startup-config` done, plus a config backup off-box:
      `show running-config` saved to a file in this repo.
- [ ] A maintenance window when CI is idle — ARC runners mid-job will fail.
- [ ] Someone available who can physically power-cycle if it hangs.

### Console status: WORKING (2026-08-05)

The SG300-52's console port is **DB-9 male**, not RJ-45. A StarTech ICUSB232FTN
(USB → DB-9 female, **null modem**) is connected to the Proxmox master and
enumerates as `/dev/ttyUSB0` via `ftdi_sio`. On its own it **could not** talk to
the switch — its null-modem crossover is wrong for this port. Adding a **DB-9
null-modem adapter (M/F) in series** cancels the crossover and the console works.

**Working configuration:** master USB → ICUSB232FTN → DB-9 null-modem adapter →
switch console port. **115200 baud, 8N1, no flow control.**

```
$ python3 /tmp/loopback2.py console
 115200:  112 bytes | User Name: ... press ENTER key to retry authentication ...
```

Lower baud rates return garbage rather than silence, which is the normal
wrong-speed signature and further confirms 115200.

Diagnosis path, for whoever hits this next — everything below was tested, not
assumed:

| Checked | Result |
|---|---|
| Driver / device node | `ftdi_sio` binds `/dev/ttyUSB0` cleanly |
| Adapter + cable | **Good** — pins 2-3 bridged echoed a 26-byte probe at all 6 baud rates |
| Connector gender | Female adapter → male switch port, mates correctly |
| Baud rate | All 6 rates silent *before* the canceller; 115200 works after |
| Switch-side config | Console is enabled by default; running-config is stock |
| Adapter TX | Transmit LED flashed on send; **RX LED never did** — the tell |

The never-flashing RX LED was the decisive symptom: both TX outputs faced each
other and our RX was tied to the switch's RX, so nothing drove it. Adding the
second crossover fixed it, confirming the diagnosis.

> **Testing gotcha.** Do not read the port with `timeout N head -c BYTES` (or
> piped `cat`). `head` blocks until it has BYTES, and when `timeout` kills it the
> block-buffered stdout is discarded — a short reply reads as total silence. This
> produced several false "cable is dead" conclusions here. Read incrementally
> with a deadline instead; see the loopback approach above.

## ⚠️ Switch commands below are UNVERIFIED

Only the commands already exercised on this box are known-good: `show version`,
`show system`, `show clock`, `show interfaces status`, `show vlan`,
`show spanning-tree`, `show lldp neighbors`, `show ip interface`,
`show mac address-table`, `show running-config`, `copy running-config
startup-config`, and the `snmp-server` / `sntp` / `logging` config lines.

Everything involving image selection and reboot — `show bootvar`,
`boot system …`, `reload` — is **written from general Cisco practice and has not
been run on this switch.** This firmware's CLI is a Cisco Small Business dialect,
not IOS, and it has already rejected one IOS-syntax command outright
(`snmp-server community <net> <mask>`; see `docs/switch-sg300.md`).

**Before the window, confirm each one interactively with `?` completion**, or plan
to drive the upgrade entirely from the web UI's Firmware Upgrade page, which
avoids the CLI-syntax question altogether and is the safer default.

## Note on SSH

The switch is **password-auth only and needs a PTY** — `ssh sg300 'some command'`
will not work (see `docs/switch-sg300.md`). Every step below assumes an
**interactive** session: run `ssh sg300`, then type commands at the prompt. Run
`terminal datadump` first or output pages at `--More--`.

For a scripted check, the pattern is `sshpass -e ssh -tt sg300 <<'CMDS'`.

## Pre-flight checks

Interactively, via `ssh sg300`:

```
terminal datadump
show version                 # confirm starting point is 1.1.2.0 / boot 1.1.0.6
show bootvar                 # UNVERIFIED — which image is active
show interfaces status       # record the 7 live ports to compare after
copy running-config startup-config
```

Capture the Grafana dashboard state (Infrastructure → SG300-52 Core Switch) so
post-upgrade throughput and error counters have a baseline.

## Execution

Per stage — do **not** batch these:

1. Upload the image via the web UI at `http://192.168.1.56/` (Administration →
   File Management → Firmware Upgrade). Preferred over TFTP/CLI — it sidesteps the
   unverified CLI syntax entirely.
2. Confirm the new image landed in the *inactive* slot before activating it. The
   web UI shows active/inactive versions directly; `show bootvar` is the CLI
   equivalent but is UNVERIFIED on this firmware.
3. Set the inactive image active, then reboot.
4. Wait for the switch to come back. Confirm from a LAN host before touching
   anything else — note `ping` is the only non-interactive check available, since
   the switch needs a PTY:
   ```
   ping 192.168.1.56
   ```
   Then `ssh sg300` interactively and run `show version` to confirm the new
   version is actually running (a failed activation silently boots the old image).
5. Verify the cluster recovered before starting the next stage:
   ```
   ssh root@192.168.1.52 "kubectl get nodes"
   ssh root@192.168.1.52 "kubectl -n observability get pods | grep -v Running"
   ```
6. Only then proceed to the next stage.

## Rollback

- **Stage 1 or 3 (firmware):** activate the other image and reboot — via the web
  UI, or from the serial console boot menu if the switch won't come up far enough
  to serve the UI. (`boot system …` is the CLI equivalent but is UNVERIFIED here.)
- **Stage 2 (boot code):** no software rollback. Serial console recovery only.
- **Config after a boot-code failure:** `startup-config` lives in flash separately
  from the boot loader, so a console recovery normally finds the saved config
  intact — but do not rely on it. The off-box `show running-config` capture from
  Prerequisites is the real safety net, and the running config here is close to
  stock, so worst case it is a short manual re-entry (SNMP community + ACL, SNTP
  server, logging host).
- **Switch unreachable and console unavailable:** the homelab is offline until
  physically resolved. This is the scenario the prerequisites exist to prevent.

## Post-upgrade verification

- [ ] `show version` reports 1.4.11.5
- [ ] `show interfaces status` — same 7 ports up, same speeds/duplex
- [ ] `show running-config` — SNMP community, SNTP server, and logging host
      survived. **Re-verify these explicitly**; config format can shift across
      major versions.
- [ ] Prometheus target healthy, `sysUpTime` reset (confirms the reboot),
      counters incrementing
- [ ] Syslog still arriving:
      `kubectl -n observability logs -l app.kubernetes.io/name=syslog-receiver`
- [ ] Modern SSH works — try plain `ssh cisco@192.168.1.56` without the legacy
      crypto opt-ins. If it connects, prune the `Host sg300` block in
      `~/.ssh/config` and update `docs/switch-sg300.md`.
- [ ] All `*.corbello.io` services reachable

## Decision record

Not yet scheduled. The upgrade is hygiene rather than a response to a known
exploited vulnerability — there is no specific CVE forcing the timeline. The
counter-argument is that a 2011 firmware on the single device carrying all homelab
traffic is a poor place to be indefinitely, and its obsolete SSH crypto is a daily
reminder.

The blocking prerequisite is serial console access. Without it, stage 2 risks
bricking the core switch with no recovery path.
