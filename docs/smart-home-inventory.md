# Smart Home Inventory

Home Assistant runs on VM 101 (`homeassistant`, `192.168.1.61`), published at
<https://ha.corbello.io> through the proxy LXC. Config lives at
`/mnt/data/supervisor/homeassistant` inside the VM; reach it without a console via
`ssh root@192.168.1.52 "qm guest exec 101 -- /bin/cat <path>"`.

Snapshot date: 2026-08-17. Regenerate with `scripts/ha-device-audit.sh`, which joins
HA's device registry against an nmap sweep of `192.168.1.0/24` run from the Proxmox
master. Proxmox cluster guests are filtered out by default (they live in
`docs/inventory.md`); pass `HA_AUDIT_ALL=1` to include them.

The join is on MAC, not IP, because several IoT devices sit in the DHCP pool and move
address. Note that it cannot match every adopted device: `homekit_controller`,
`playstation_network` and `mobile_app` identify by accessory ID and register no MAC at
all, so those are reported in a separate section and must be checked by hand.

## Adopted by Home Assistant

| Device | Model | IP | Notes |
|--------|-------|-----|-------|
| Upstairs thermostat | ecobee3 lite | .39 | Primary HVAC. Paired via `homekit_controller`, NOT the ecobee integration |
| Juliettes Room | ecobee EBERS41 | — | Remote room sensor |
| Lukes Room | ecobee EBERS41 | — | Remote room sensor |
| LG webOS TV 05AD | OLED77C1PUB | — | |
| PlayStation 5 | PS5 | — | Plus a second `shdwcld` PSN entry |
| Jeremy's iPhone | iPhone 17 | .197 | Companion app |
| Matter Server | HA add-on 8.1.0 | — | No Matter devices paired yet |

Non-device integrations: Sun, Met.no forecast, File editor add-on.

## On the network, not in Home Assistant

Everything below answers ARP but has no HA device entry. Most have a first-party
integration available.

### Climate

| Device | IP | MAC vendor | Integration |
|--------|-----|-----------|-------------|
| Downstairs thermostat | .143 | ecobee | Needs the `ecobee` integration adding (API key from `developer.ecobee.com`) |

There is **no `ecobee` integration configured** — verified against
`.storage/core.config_entries`. The Upstairs unit reached HA over HomeKit instead, which
is why only one of the two thermostats is present. Adding the real ecobee integration is
account-wide and picks up both thermostats plus the remote sensors; the
`homekit_controller` entry for Upstairs should be deleted afterwards so one integration
owns the hardware.

### Lighting and plugs (TP-Link Kasa)

| Device | IP | Model | Protocol | Credentials |
|--------|-----|-------|----------|-------------|
| Courtney's lamp | .23 | HS103 | legacy (tcp/9999) | none |
| Jeremy's lamp | .79 | HS103 | legacy (tcp/9999) | none |
| My Swag | .117 | HS100 | legacy (tcp/9999) | none |
| Wall switch | .234 | HS200 | KLAP (tcp/80) | TP-Link cloud login |
| Dimmer switch | .248 | HS220 | KLAP (tcp/80) | TP-Link cloud login |

All use the `tplink` integration, but the fleet is split across two firmware
generations. The three legacy devices answer the plaintext protocol on 9999 and adopt
with no credentials. `.234` and `.248` answer only on 80 — newer KLAP firmware, which
requires a TP-Link cloud login during the config flow even though control stays local.

**None of these models has energy monitoring.** HS103/HS100/HS200/HS220 report no
emeter, so per-device power or cost dashboards are not buildable on this hardware.
That needs HS110 or KP115 devices.

### Lighting (Leviton)

| Device | IP |
|--------|-----|
| Leviton-Device-6B45 | .33 |
| Leviton-Device-DA59 | .84 |

Decora Smart — `decora_wifi` (cloud) or Matter, depending on generation.

### Cameras and doorbells

| Device | IP | Vendor |
|--------|-----|--------|
| Nest Cam (indoor) | .104 | Google — needs Nest/SDM cloud project |
| Ring device | .65 | Ring Solutions |
| Ring Chime | .180 | Ring Solutions |

### Appliances

| Device | IP | Vendor |
|--------|-----|--------|
| Samsung Range | .3 | SmartThings integration |
| Samsung Microwave | .217 | SmartThings integration |
| Garage door controller (`gdocntl`) | .24 | Texas Instruments Wi-Fi module — identify make before integrating |
| Peloton | .192 | No official integration |

### Media and voice

| Device | IP | Vendor |
|--------|-----|--------|
| Roku (`Master`) | .225 | `roku` integration |
| Apple device (`Living-Room`) | .20 | Apple TV — `apple_tv` integration |
| Amazon Echo | .108, .129, .159, .172 | Four devices; no local integration |
| Nintendo Switch | .119 | None |

### Other

| Device | IP | Notes |
|--------|-----|-------|
| Brother printer | .21 | `BRW44F79FE34A8D` |
| ASUS ZenWiFi BQ16 Pro | .1 | Router — `asuswrt` integration for presence/traffic |
| Cisco SG300-52 | .56 | Core switch, see `docs/` network notes |
| Unidentified Wi-Fi modules | .6, .145, .156, .196, .203 | TI / USI / FN-Link / lwIP stacks — almost certainly IoT, unlabeled |
| Unidentified | .7, .11, .44, .105, .155, .177, .204, .209, .219 | No hostname, no vendor match |

Proxmox guests and cluster VMs are omitted here; they live in `docs/inventory.md`.

## Addressing

Static reservations sit below `.200`; the router's DHCP pool is `.200-.250` (moved there
after a pool/static overlap outage — see `docs/network-reservations.md`). A handful of
IoT devices currently hold leases between `.190` and `.199`, outside both ranges. Harmless
today, but reserve anything you want to address by IP.

These smart-home devices currently sit **inside** the DHCP pool and will drift:

| Device | IP |
|--------|-----|
| HS200 wall switch | .234 |
| HS220 dimmer | .248 |
| Roku (`Master`) | .225 |

Adoption survives the drift — the `tplink` and `roku` integrations track devices by MAC,
not address — but anything referencing these by IP needs a router reservation.
