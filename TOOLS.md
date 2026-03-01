# TOOLS.md - Local Notes

Skills define *how* tools work. This file is for *your* specifics — the stuff that's unique to your setup.

---

## Google (Gmail + Calendar)

**Location:** `~/clawd/tools/google/`  
**Symlinks:** `~/clawd/bin/gmail`, `~/clawd/bin/gcal`

### Authorized Accounts
- `jacorbello@gmail.com` — personal
- `jeremy@familyfriendlyinc.com` — work

### Quick Commands
```bash
gmail list --unread -n 10           # List unread messages
gcal today                          # Today's events
# Use -a to switch account: gmail list -a familyfriendly
```

---

## Infrastructure Quick Reference

### Proxmox
- **Primary:** `ssh root@192.168.1.52` (cortech)
- **Version:** Proxmox VE 9.1.4
- **Key VMs:** proxy(100), k3s-*(200-204), redis(116), postgres(114)
- *Details:* `memory_search("Proxmox infrastructure")`

### k3s Cluster
- **Master:** `ssh k3s@192.168.1.91`
- **NFS Storage:** 192.168.1.114 (cortech-node3)
- **Storage Class:** `nfs-node3` (prefer over local-path)
- *Details:* `memory_search("k3s NFS storage")`

### Key Services
| Service | Host/URL | Port | Purpose |
|---------|----------|------|---------|
| **n8n** | https://n8n.corbello.io | 5678 | Workflow automation |
| **Grafana** | https://grafana.corbello.io | — | Monitoring (admin/qma!aqk1vtr6vum_AEK) |
| **Qdrant** | 192.168.1.91:30333 | 30333 | Vector database |
| **Redis** | 192.168.1.86:6379 | 6379 | Cache/queue |
| **Uptime Kuma** | 192.168.1.121:3001 | 3001 | Status monitoring |
| **MinIO** | 192.168.1.118 | 9000/9001 | Object storage |
| **Postal** | https://postal.corbello.io | — | Email server |

*Full details available via memory_search*

---

## STT/TTS Server (Whisper + Piper)

**Host:** 192.168.1.96:8880  
**Primary Voice:** `en_GB-northern_english_male-medium` (British male)  
**Fallback Voice:** OpenAI TTS (male voice)

```bash
# Health check
curl http://192.168.1.96:8880/health

# Basic TTS
curl -X POST http://192.168.1.96:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world", "voice": "en_GB-northern_english_male-medium"}' \
  -o output.mp3

# Basic STT
curl -X POST http://192.168.1.96:8880/v1/audio/transcriptions -F "file=@audio.wav"
```

---

## Semantic Memory (Alastar)

**Tool:** `~/clawd/bin/alastar-index`  
**Qdrant:** http://192.168.1.91:30333  

```bash
alastar-index --search "How do heartbeats work?"    # Search all collections
alastar-index --all                                 # Re-index everything
```

---

## Secrets Management

### Infisical
- **URL:** https://infisical.corbello.io
- **Project:** `homelab` (c00e26a9-9389-4cc8-9b74-75f936dfeb81)
- *CLI setup:* `~/clawd/projects/secrets-vault/CLI_SETUP.md`

### 1Password CLI
- **Vault:** `Alastar` (jacorbello@gmail.com)
- **Requires:** tmux session + desktop app unlocked
- **Quick:** `op item list --vault Alastar`

---

## Investigation Tools

### Cortech Investigations
- **Case files:** `~/clawd/investigations/`
- **MinIO bucket:** `homelab/investigations/`

### OSINT & Tools
- **theHarvester:** http://192.168.1.91:30502 (domain OSINT)
- **ArchiveBox:** http://192.168.1.91:30800 (web archiving)
- **MD2PDF:** `~/clawd/bin/md2pdf` (report generation)

---

## Task Queue & Webhooks

### Alastar Task Queue (BullMQ)
- **Dashboard:** http://192.168.1.91:30380
- **Backend:** Redis 192.168.1.86:6379

### Alastar Webhook Receiver
- **URL:** http://192.168.1.91:30080/webhook/:source
- **Health:** http://192.168.1.91:30080/health

---

## Email & Communication

### Postal Email Server
- **Web UI:** https://postal.corbello.io
- **Host:** 192.168.1.82 (LXC 113)
- **API Key:** `YJLYrJPZ96ZHK8wP3Zk8xRE7` (meridian-bridge-mail server)

---

## DNS Management

### Namecheap DNS API
**Tool:** `~/clawd/bin/namecheap-dns`  
**Whitelisted IP:** `24.28.98.7` (Mac Mini)

```bash
namecheap-dns list <domain>                          # List all records
namecheap-dns add <domain> A www 1.2.3.4             # Add record
```

---

## Authentication

### Clerk (PlotLens Auth)
- **Dashboard:** https://dashboard.clerk.com
- **Test Secret:** `sk_test_t1eRGKHzfhhCGuxfnQyvKmUIyMsXomKxkcXJSeU4dz`
- **Mode:** Test (development)

---

## External APIs

### xAI (Grok)
- **API Key:** Infisical → `homelab` project → `XAI_API_KEY`
- **Models:** `grok-3`, `grok-3-fast`, `grok-4-fast-reasoning`

---

## GitHub Automation
- **Ignore:** `Striveworks` organization — no automation, alerts, or actions

---

## Local Conventions

### 🎙️ Voice Preferences
- **Primary:** Local Kokoro server (192.168.1.96:8880) — northern English male
- **Fallback:** OpenAI TTS — male voice only

### 📝 Platform Formatting
- **Discord/WhatsApp:** No markdown tables! Use bullet lists
- **Discord links:** Wrap in `<>` to suppress embeds
- **WhatsApp:** No headers — use **bold** or CAPS

### 🔧 Development
- **Commit format:** `type(scope): description\n\nCloses #<issue>`
- **Types:** feat, fix, docs, style, refactor, test, chore, ci

---

*For detailed infrastructure documentation, use memory_search() to find specific details.*