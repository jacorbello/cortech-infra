# Runbook: SG300-52 firmware upgrade (1.1.2.0 → 1.4.11.5)

**Status: planned, not executed.** Nothing in here has been run. See
`docs/switch-sg300.md` for the switch itself.

## Why this is not a one-step upgrade

Cisco requires stepped upgrades from firmware older than 1.3.5. The direct jump
from 1.1.2.0 to 1.4.x is unsupported and fails.

Path below is from Cisco's own release notes for 1.4.11.5 (§ *Change in Flash File
System*), retrieved via the Wayback Machine — Cisco has retired the 300 Series and
removed the originals.

| Stage | Step | Reboot | Rollback |
|-------|------|--------|----------|
| 1 | firmware 1.1.2.0 → **1.3.5.58** | yes + flash migration | **none after this — see below** |
| 2 | boot file → **1.3.5.06** | yes | none |
| 3 | firmware → **1.4.1.3** | yes | boot inactive image |
| 4 | firmware → **1.4.11.5** | yes | boot inactive image |

Four stages, not three. Budget 60–120 minutes with verification between each.

> **Sx300 takes 1.3.5.x, not 1.3.7.x.** The release notes specify 1.3.7.x for
> **Sx500** models only. An earlier draft of this runbook had 1.3.7.18 for stage 1,
> which is the wrong branch for this device.

Cisco's text, verbatim:

> When upgrading the device from version prior to 1.3.5.x:
> • For Sx200/Sx300 models, first upgrade the device image to image version
> 1.3.5.x and upgrade the boot file to 1.3.5.06
> […]
> After the device is running version 1.3.5.x/1.3.7.x, you can upgrade the device
> to version 1.4.0.48 or 1.4.1.3

Going straight from 1.3.5.x to 1.4.11.5 is not the documented path. Community
posts describe it failing with a "file too large" error — **anecdotal and
uncited**; the load-bearing reason to step via 1.4.1.3 is that it is what Cisco
documents, not that report.

### Stage 1 destroys the rollback image

This is the single most important fact in this runbook, and it reverses an earlier
claim here that the 1.1.2.0 rollback was "real":

> During the first bootup of the new image version (1.3.5.x or 1.3.7.x), the flash
> file system is upgraded and:
> • This process takes a few minutes. "…" progress in the console is displayed
> • The syslog file is deleted during this process.
> • **The original image file is deleted. The two images on the Flash after the
> upgrade will have the same version (1.3.5.x/1.3.7.x).**

So the moment stage 1 completes, **1.1.2.0 is gone from both slots.** There is no
going back to the current firmware by activating the other image. Getting back to
pre-1.3.5 afterwards is a *downgrade* operation that rewrites the flash file
system, and Cisco warns:

> Powering off the device during this process might damage the file system. In such
> cases, booting might require connecting to the device using the console cable and
> loading the image file using XMODEM.

**Practical consequence:** starting stage 1 commits you to at least 1.3.5.58.
Consider that the point of no return, not stage 2.

### The one genuinely dangerous step

Boot code (stage 2) has no second slot. An interrupted or corrupt boot-code flash
bricks the switch and the only recovery is serial console + XMODEM.

Stages 3 and 4 keep a real rollback: the inactive slot holds the previous 1.4.x
image.

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
- [x] **All four firmware artifacts obtained and verified 2026-08-06**
      (`1.3.5.58`, boot `1.3.5.06`, `1.4.1.3`, `1.4.11.5`) — per-file verification
      strength differs; read *Firmware provenance* below before stage 1. Cisco
      retired the line and removed the downloads, so these came from the Internet
      Archive rather than Cisco.
- [ ] **Back up the current 1.1.2.0 image off-box before stage 1** — the flash
      migration deletes it and it can no longer be downloaded from Cisco. If
      `copy image tftp://…` works on this firmware (UNVERIFIED), use it. Without
      this, returning to 1.1.2.0 is impossible, not merely risky.
- [x] **Config backup captured 2026-08-06** via `scripts/sg300-config-backup.sh`
      (`~/cortech-backups/`, full copy mode 600 + redacted copy). **Re-run
      immediately before the window**, and run `copy running-config
      startup-config` on the switch first. **Do not commit the full config** — it
      contains the local user's password hash and the SNMP community string; the
      script keeps it outside the repo and fails if redaction did not take.
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

## Firmware provenance

Cisco retired the 300 Series and removed the downloads; all three official release
URLs are dead (verified 2026-08-06). Files came from the Internet Archive, so they
are **not Cisco-hosted binaries** and Cisco's published checksums are gone with the
pages. What was verified instead:

| Artifact | Size | Verification |
|---|---|---|
| `Sx300-FW-1.4.11.5.bin` | 7,494,516 | SHA-256 `4a715c35…d0c078` — **exact match** to an independently-reported hash from a copy extracted off a switch originally flashed by Cisco, in a different archive item under a different filename |
| `Boot-Code-1.3.5.06.rfb` | 393,232 | **Byte-identical** to `sx300_boot-13506.rfb` in a second, unrelated archive item, apart from an 8-byte flash-state prefix (`00…` vs `FF…`) before the `CI03` magic |
| `sx300_fw-1413.ros` | 7,394,631 | Correct Cisco image magic; MD5/SHA-1/size match the archive manifest. **Single-source** |
| `Sx300-FW-1.3.5.58.bin` | 6,976,867 | Correct Cisco image magic (`CI032.00P` + `PACK`). **Single-source** |

All four artifacts are in hand as of 2026-08-06.

> **The irreversible step rests on the weakest-verified file.** Stage 1 uses
> `1.3.5.58`, which is single-source — and stage 1 is the point of no return. The
> two well-corroborated artifacts (1.4.11.5, boot 1.3.5.06) are used in later
> stages, two of which have real rollbacks. That asymmetry is worth accepting
> deliberately rather than by accident.

**Why 1.4.1.3 and not 1.4.0.48:** Cisco names either as valid. 1.4.1.3 was chosen
because it is what could be sourced from the Archive; nothing in the release notes
favours one over the other for this SKU.

All files carry genuine Cisco image headers, not archive containers. The SG300
bootloader validates an image's own checksum before committing, so a *corrupt*
file is rejected rather than flashed. The residual risk is a deliberately crafted
valid-but-malicious image — judged low for an obscure 2011–2016 firmware archive,
but it is a real, accepted risk, not an eliminated one.

## ⚠️ Switch commands below are UNVERIFIED

Only the commands already exercised on this box are known-good: `show version`,
`show system`, `show clock`, `show interfaces status`, `show vlan`,
`show spanning-tree`, `show lldp neighbors`, `show ip interface`,
`show mac address-table`, `show running-config`, **`show bootvar`**, `copy
running-config startup-config`, and the `snmp-server` / `sntp` / `logging` config
lines.

Everything involving image *selection* and reboot — `boot system …`, `reload` —
is **written from general Cisco practice and has not been run on this switch.** This firmware's CLI is a Cisco Small Business dialect,
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
show bootvar                 # which image is active — verified working
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
2. Confirm the new image landed in the *inactive* slot before activating it.
   `show bootvar` reports this directly and is verified working:
   ```
   Image  Filename   Version     Status
   1      image-1    1.1.2.0     Active*
   2      image-2    1.1.2.0     Not active
   ```
3. Set the inactive image active, then reboot.
   **On stage 1's first boot the flash file system migrates.** This takes several
   minutes, shows `…` progress on the serial console, deletes the syslog file, and
   leaves both image slots on 1.3.5.58. Do **not** power-cycle during it — Cisco
   warns this can damage the file system and force XMODEM recovery. Watch it on
   the console rather than guessing from ping.
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

Stage order matters: **image first, then boot file.** Cisco's wording is "first
upgrade the device image to 1.3.5.x and upgrade the boot file to 1.3.5.06".

Cisco states the boot file cannot be downgraded while a 1.4.0.x/1.4.1.x image is
active — though it says so *within* its downgrade-to-below-1.3.5 procedure, not as
a general rule. **Inference, not Cisco's stated conclusion:** treat boot-code
reversal as something that must happen before stage 3. Erring conservative here
costs nothing.

## Rollback

- **Stage 1 — no rollback.** The flash migration deletes 1.1.2.0 from both slots.
  Once stage 1 boots, the earliest reachable version is 1.3.5.58. Returning to
  pre-1.3.5 later is a file-system-rewriting downgrade that Cisco warns can damage
  flash if interrupted.
- **Stage 2 (boot code):** no software rollback. Serial console + XMODEM only.
- **Stages 3 and 4 (firmware):** activate the other image and reboot — via the web
  UI, or the serial console boot menu if the switch won't serve the UI.
  (`boot system …` is the CLI equivalent but is UNVERIFIED here.) The inactive slot
  holds the previous 1.4.x image, so these rollbacks are real.
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
- [ ] `show bootvar` shows both slots on the expected version
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
