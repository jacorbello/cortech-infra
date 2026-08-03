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
| gi50 | router uplink — all WAN and household traffic |

Consequences per reboot:

- K3s nodes mark each other `NotReady`; etcd loses quorum for the duration
- All public ingress via proxy LXC 100 is down
- NFS mounts may hang. Per `k3s-wrk-3-egress-packet-loss` notes, hung NFS on
  k3s-wrk-3 has historically cleared only via `qm reset 206`
- Guests do **not** reliably auto-start after an unclean stop — see
  `power-loss-guests-no-autostart` — so a node that hard-fails needs manual
  recovery in dependency order

## Prerequisites

- [ ] **Serial console cable** (RJ-45 console port) and a tested connection to a
      laptop. Non-negotiable for stage 2.
- [ ] Physical access to the switch.
- [ ] Firmware images downloaded and checksummed **before** the window:
      `1.3.7.18`, boot code `1.3.5.06`, `1.4.11.5`. Requires a Cisco.com account;
      the SG300 line is effectively end-of-support, so confirm the downloads still
      resolve before scheduling.
- [ ] `copy running-config startup-config` done, plus a config backup off-box:
      `show running-config` saved to a file in this repo.
- [ ] A maintenance window when CI is idle — ARC runners mid-job will fail.
- [ ] Someone available who can physically power-cycle if it hangs.

## Pre-flight checks

```
ssh sg300
show version                 # confirm starting point is 1.1.2.0 / boot 1.1.0.6
show bootvar                 # which image is active
show interfaces status       # record the 7 live ports to compare after
copy running-config startup-config
```

Capture the Grafana dashboard state (Infrastructure → SG300-52 Core Switch) so
post-upgrade throughput and error counters have a baseline.

## Execution

Per stage — do **not** batch these:

1. Upload the image (web UI at `http://192.168.1.56/` is simplest, or TFTP).
2. `show bootvar` — confirm the new image landed in the *inactive* slot.
3. Set the inactive image active, then `reload`.
4. Wait for the switch to come back. Confirm from a LAN host before touching
   anything else:
   ```
   ping 192.168.1.56
   ssh sg300 'show version'
   ```
5. Verify the cluster recovered before starting the next stage:
   ```
   ssh root@192.168.1.52 "kubectl get nodes"
   ssh root@192.168.1.52 "kubectl -n observability get pods | grep -v Running"
   ```
6. Only then proceed to the next stage.

## Rollback

- **Stage 1 or 3 (firmware):** boot the inactive image from the boot menu or
  `boot system image-1|image-2`, then reload.
- **Stage 2 (boot code):** no software rollback. Serial console recovery only.
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
