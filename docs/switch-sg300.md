# Cisco SG300-52 core switch

The single LAN switch every homelab host sits behind. Unmanaged in practice — the
running-config is close to factory default.

- **Model:** SG300-52, 52-port Gigabit managed switch (`switch781f24`)
- **Management:** `192.168.1.56` (web UI is HTTP-only; 443 is closed)
- **Base MAC:** `f4:ea:67:78:1f:24`
- **Firmware:** 1.1.2.0 (12-Nov-2011), boot 1.1.0.6, HW V02
- **Credentials:** user `cisco` (privilege 15), password in Infisical `homelab` →
  `CISCO_SG300_PASSWORD`

## Access

Its 2011-era SSH stack is refused outright by modern OpenSSH, so four legacy
opt-ins are required. They live in `~/.ssh/config` on the dev machine:

```
Host sg300
  HostName 192.168.1.56
  User cisco
  KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
  HostKeyAlgorithms +ssh-rsa
  PubkeyAcceptedAlgorithms +ssh-rsa
  Ciphers +aes256-cbc,aes128-cbc,3des-cbc
  MACs +hmac-sha1,hmac-md5
  RequestTTY yes
```

Then `ssh sg300`. Run `terminal datadump` first in any session — without it the
switch paginates every command at `--More--`.

Password auth only; no key auth and no PTY-less login, so the switch **cannot be
driven from a non-interactive shell**. Scripted `show` collection needs `sshpass`
plus `ssh -tt`, and even then the password must come from a real terminal.

## Port map

Derived from `show mac address-table` cross-referenced against the Proxmox master's
ARP table. `bc:24:11:*` is the Proxmox OUI, so those entries are guests rather than
physical hosts.

| Port | Device | IP | Notes |
|------|--------|-----|-------|
| gi1  | cortech-node1 | 192.168.1.72 | + 1 guest |
| gi2  | cortech (master) | 192.168.1.52 | + 11 guests — proxy LXC 100 lives here |
| gi3  | unidentified | 192.168.1.49 | not a Proxmox node, not in the guest table |
| gi44 | cortech-node2 | 192.168.1.60 | + 1 guest |
| gi47 | cortech-node5 | 192.168.1.80 | + 2 guests |
| gi48 | cortech-node3 (GPU) | 192.168.1.114 | + 3 guests incl. k3s-wrk-3 `.97` |
| gi50 | router uplink | 192.168.1.1 | ~33 MACs — all household devices + WAN |

All other ports are down. 7 of 52 in use.

## Current configuration

Effectively stock. The entire non-default running-config is a hostname, one user,
`ip ssh server`, six SNMP v3 groups, and the boilerplate voice-VLAN OUI table.

- **VLANs:** none — every port is untagged VLAN 1
- **Port descriptions:** none
- **LAG:** none — `Po1-8` all `Not Present`, so every node is single-homed
- **STP:** RSTP on, switch is root at default priority 32768 (won on MAC address,
  not by configuration). 71 topology changes lifetime.
- **LLDP:** enabled, zero neighbors — nothing else on the LAN speaks it
- **SNMP:** v3 groups defined but no user or community exists, and port 161 is
  closed. Nothing is listening.
- **Syslog:** no remote host

## Known issues

1. **Firmware is ~14 years old.** 1.1.2.0 shipped Nov 2011; the final SG300 release
   is 1.4.11.x. Its obsolete SSH ciphers are a direct symptom.
2. **Management IP is a DHCP lease, not static.** `show ip interface` reports
   `192.168.1.56/24 vlan 1 DHCP`. The router's DHCP pool was later moved to
   `.200-.250` (see `network-reservations.md`), so `.56` is a lease from the old
   pool — on renewal the management address will move and `ssh sg300` breaks.
   Should be a static IP.
3. **No time source.** `show clock` reads Dec 2011 with `No time source`, making
   every switch-side timestamp meaningless. Needs SNTP against `192.168.1.1`.
4. **Invisible to monitoring.** With SNMP not listening and no syslog target, the
   Prometheus/Loki stack gets no port counters, no link-flap alerts, and no error
   rates from the device every homelab packet crosses.
5. **Single points of failure.** No LAG on any node. Losing one port or cable
   isolates a whole Proxmox host — for gi2 that is the master plus 11 guests
   including the public-ingress proxy.

## Related

- `network-reservations.md` — WAN, DHCP pool, and port-forward details
