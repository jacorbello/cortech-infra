# Smart Home Inventory

Home Assistant runs on VM 101 (`homeassistant`, `192.168.1.61`), published at
<https://ha.corbello.io> through the proxy LXC. Config lives at
`/mnt/data/supervisor/homeassistant` inside the VM; reach it without a console via
`ssh root@192.168.1.52 "qm guest exec 101 -- /bin/cat <path>"`.

Snapshot date: 2026-08-17. Sourced from HA's device registry plus an ARP sweep of
`192.168.1.0/24` from the Proxmox master. Hand-maintained — re-run the sweep to refresh.

## Adopted by Home Assistant

| Device | Model | IP | Notes |
|--------|-------|-----|-------|
| Upstairs thermostat | ecobee3 lite | .39 | Primary HVAC |
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
| Downstairs thermostat | .143 | ecobee | Already-configured `ecobee` integration — this one is simply unadopted |

### Lighting and plugs (TP-Link Kasa)

| Device | IP | Type |
|--------|-----|------|
| HS103 | .23 | Smart plug |
| (HS103 sibling) | .79 | Smart plug |
| HS100 | .117 | Smart plug |
| HS200 | .234 | Wall switch |
| HS220 | .248 | Dimmer switch |

`tplink` integration, local push, no cloud account needed.

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
