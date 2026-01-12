# Jarvis Assistant - Project Plan

LAN-only AI assistant with LibreChat frontend and AGiXT agent executor.

## Architecture

```
PCT 100 (proxy)
├── chat.corbello.io    → LibreChat UI
└── jarvis.corbello.io  → AGiXT API (internal)

PCT 121 (jarvis) - Docker Compose stack
├── LibreChat      - Multi-user chat UI, auth, sessions
├── AGiXT          - Agent executor, tool orchestration
├── Tools Gateway  - Allowlisted safe actions
└── RAG Service    - Document retrieval

PCT 114 (postgres) - Database + pgvector
PCT 116 (redis)    - Sessions, caching
```

## Status

| Phase | Status | Description |
|-------|--------|-------------|
| 0 | COMPLETE | Project setup and planning |
| 1 | COMPLETE | Infrastructure (PCT 121, Docker) |
| 2 | COMPLETE | LibreChat deployment |
| 3 | COMPLETE | AGiXT deployment + integration |
| 4 | COMPLETE | RAG pipeline + pgvector |
| 5 | COMPLETE | Tools Gateway |
| 6 | COMPLETE | Ingress configuration |
| 7 | NOT_STARTED | WhatsApp bridge (optional) |
| 8.1 | COMPLETE | iOS Attention System - Push + Inbox |
| 8.2 | COMPLETE | iOS Attention System - Action Callbacks |
| 8.3 | COMPLETE | iOS Attention System - Daily Digest |
| 8.4 | COMPLETE | iOS Attention System - Approval Gates |
| 8.5 | COMPLETE | iOS Attention System - Escalation & Reliability |
| 9.1 | IN_PROGRESS | Discord Bridge - Basic Sessions |
| 9.2 | NOT_STARTED | Discord Bridge - Projects + Pins |
| 9.3 | NOT_STARTED | Discord Bridge - Buttons + Approvals |
| 9.4 | NOT_STARTED | Discord Bridge - Operational Hardening |

## Container Info

| Property | Value |
|----------|-------|
| VMID | 121 |
| Hostname | jarvis |
| IP Address | 192.168.1.117 |
| Node | cortech |
| RAM | 16 GiB |
| CPU | 6 cores |
| Disk | 50 GiB |
| Docker | 29.1.4 |
| Compose | 5.0.1 |

---

## Phase 0: Project Setup

### TODOs
- [x] Create project folder structure
- [x] Write project plan with TODOs
- [x] Document architecture decisions (ADR)
- [x] Define resource allocation for PCT 121

### Decisions
- **Frontend**: LibreChat (multi-user, MCP support)
- **Agent Engine**: AGiXT (plugin system, autonomy)
- **Deployment**: Single LXC (PCT 121) with Docker Compose
- **Database**: Reuse PCT 114 postgres (add pgvector)
- **Cache**: Reuse PCT 116 redis
- **Ingress**: PCT 100 proxy (NGINX + certbot)

---

## Phase 1: Infrastructure

### TODOs
- [x] Create PCT 121 `jarvis` container
  - Template: Ubuntu 22.04
  - Resources: 16 GiB RAM, 6 vCPU, 50 GiB disk
  - Network: DHCP (192.168.1.117)
  - Node: cortech (master)
- [x] Install Docker and Docker Compose in PCT 121
- [x] Configure container for nested Docker (nesting=1, keyctl=1)
- [ ] Add PCT 121 to infrastructure inventory
- [x] Create `jarvis/` directory in infra repo for configs

### Files Created
- `pct/121-jarvis.conf` - Container configuration
- `jarvis/docker-compose.yml` - Service stack (pending)
- `jarvis/.env.example` - Environment template (pending)

---

## Phase 2: LibreChat Deployment

### TODOs
- [x] Create LibreChat docker-compose service
- [x] Configure LibreChat environment variables
- [x] Set up LibreChat database in PCT 114 postgres
  - Database: `librechat_rag` (for RAG/vectors)
  - User: `librechat`
  - pgvector 0.8.1 extension enabled
- [x] Configure MongoDB (runs in docker-compose)
- [x] Configure Meilisearch (runs in docker-compose)
- [x] Configure authentication (local auth enabled)
- [x] Test LibreChat UI access locally (http://192.168.1.117:3080)
- [x] Add LLM API keys (OPENAI_API_KEY, ANTHROPIC_API_KEY)

### Configuration
- [x] `jarvis/docker-compose.yml` - Service stack
- [x] `jarvis/librechat.yaml` - LibreChat config
- [x] `jarvis/.env` - Environment (on PCT 121, not in repo)
- [x] Secrets: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` configured

### Verification
- [x] LibreChat UI accessible at http://192.168.1.117:3080
- [x] RAG API connected to pgvector
- [x] LLM API keys configured
- [x] Create user account and test chat

---

## Phase 3: AGiXT Deployment

### TODOs
- [ ] Add AGiXT services to docker-compose
- [ ] Configure AGiXT environment
- [ ] Disable dangerous extensions (shell execution)
- [ ] Enable safe extensions:
  - [x] Web browsing / search
  - [ ] File read (restricted paths)
  - [ ] HTTP requests (to Tools Gateway only)
- [x] Integrate AGiXT with LibreChat
  - Option A: MCP server mode
  - Option B: Custom endpoint ← **Implemented**
- [x] Test agent execution from LibreChat (via /v1/chat/completions)

### Configuration
- [ ] `jarvis/agixt/` - AGiXT configuration directory
- [ ] Define allowed extensions list

### Verification
- [ ] Agent can browse web
- [x] Agent can be invoked from LibreChat (Jarvis Agent endpoint)
- [x] Shell execution is disabled (no docker.sock mount)

---

## Phase 4: RAG Pipeline

### TODOs
- [ ] Install pgvector extension on PCT 114
  ```bash
  pct exec 114 -- apt install postgresql-15-pgvector
  pct exec 114 -- psql -U postgres -c "CREATE EXTENSION vector;"
  ```
- [ ] Create embeddings table schema
- [ ] Build document ingestion pipeline
  - Source: Git repos (infrastructure, docs)
  - Formats: Markdown, PDF, code files
- [ ] Configure chunking strategy
- [ ] Set up embedding generation (OpenAI or local)
- [ ] Create retrieval API endpoint
- [ ] Integrate RAG with LibreChat/AGiXT

### Data Sources (Initial)
- [ ] `/root/repos/infrastructure/docs/`
- [ ] `/root/repos/infrastructure/plans/`
- [ ] Add more sources as needed

### Configuration
- [ ] `jarvis/rag/` - RAG service code
- [ ] Embedding model selection

### Verification
- [ ] Documents are chunked and embedded
- [ ] Semantic search returns relevant results
- [ ] Citations include source file and location

---

## Phase 5: Tools Gateway

### TODOs
- [ ] Create Tools Gateway service (FastAPI)
- [ ] Implement authentication (API key)
- [ ] Define initial safe actions:
  - [ ] `POST /actions/search_docs` - RAG query
  - [ ] `POST /actions/webhook` - Call allowlisted webhooks
  - [ ] `POST /actions/create_issue` - GitHub issue creation
  - [ ] `POST /actions/read_file` - Read from allowlisted paths
- [ ] Implement audit logging
- [ ] Add rate limiting
- [ ] Register Tools Gateway as AGiXT extension

### Security Rules
- No arbitrary command execution
- No arbitrary file paths (allowlist only)
- All inputs validated against strict schemas
- All actions logged with timestamp, user, inputs, result

### Configuration
- [ ] `jarvis/tools-gateway/` - Service code
- [ ] `jarvis/tools-gateway/actions.yaml` - Allowlisted actions
- [ ] `jarvis/tools-gateway/webhooks.yaml` - Allowlisted webhook URLs

### Verification
- [ ] Unauthorized requests are rejected
- [ ] Only allowlisted actions execute
- [ ] Audit log captures all requests

---

## Phase 6: Ingress Configuration

### TODOs
- [x] Add DNS record for `chat.corbello.io` (CNAME → corbello.ddns.net)
- [ ] Add DNS record for `jarvis.corbello.io` (for AGiXT, Phase 3)
- [x] Configure NGINX on PCT 100:
  - [x] `chat.corbello.io` → 192.168.1.117:3080 (LibreChat)
  - [ ] `jarvis.corbello.io` → PCT 121 AGiXT port (Phase 3)
- [x] Generate TLS certificate via certbot (expires 2026-04-09)
- [x] Test external access via `https://chat.corbello.io`
- [ ] Verify Authelia protection (optional, not configured)

### Configuration
- [x] `proxy/sites/chat.corbello.io.conf` - NGINX config saved to repo
- [ ] Update `dns/` Terraform if managing DNS as code (DNS added manually)

### Verification
- [ ] HTTPS works for chat.corbello.io
- [ ] Certificate is valid
- [ ] Auth works as expected

---

## Phase 7: WhatsApp Bridge (Optional)

### TODOs
- [ ] Decide on exposure strategy:
  - [ ] Option A: Cloudflare Tunnel for webhook only
  - [ ] Option B: Small cloud relay function
  - [ ] Option C: Skip WhatsApp, use LAN-only
- [ ] Set up Twilio account and WhatsApp sender
- [ ] Build webhook receiver service
- [ ] Map WhatsApp sender → LibreChat user
- [ ] Implement Twilio signature verification
- [ ] Test end-to-end message flow

### Configuration
- [ ] `jarvis/whatsapp-bridge/` - Bridge service
- [ ] Secrets: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`

---

## Phase 8: iOS Attention System (Home Assistant Integration)

Jarvis can proactively contact the user via iOS push notifications through Home Assistant.

### Architecture
```
Jarvis Agent → Tools Gateway → Home Assistant (VM 101) → iOS Push
                    ↑                    ↓
              Audit Log           User Action Button
                    ↑                    ↓
              Callback ←─────────────────┘
```

### Phase 8.1: Push + Inbox (COMPLETE)

#### TODOs
- [x] Add `notify_attention` endpoint to Tools Gateway
- [x] Implement HMAC signing for HA communication
- [x] Add dedupe store (in-memory, 1-hour TTL)
- [x] Create HA webhook automation (`jarvis_attention_ingest`)
- [x] Configure iOS push notifications per severity
- [x] Store notifications in HA persistent notifications (Inbox)
- [x] Update docker-compose with HA env vars
- [x] Deploy HA automation via VM disk mount

#### Configuration
- [x] `jarvis/homeassistant/jarvis_attention.yaml` - HA package
- [x] `HA_WEBHOOK_URL=http://192.168.1.61:8123/api/webhook/jarvis_attention`
- [x] `HA_WEBHOOK_SECRET` - Shared HMAC secret

#### Verification
- [x] FYI notification reaches iPhone
- [x] Notification appears in HA persistent notifications
- [x] Audit log records all notifications

---

### Phase 8.2: Action Callbacks (COMPLETE)

#### TODOs
- [x] Add `attention_callback` endpoint to Tools Gateway
- [x] Create HA automation for notification actions
- [x] LAN trust for callbacks (192.168.1.x trusted without HMAC)
- [x] Test ACK → dismiss notification flow
- [x] Test SNOOZE → log snooze request
- [x] iOS action buttons working (long-press to reveal)

#### Verification
- [x] ACK button dismisses notification and logs action
- [x] All callbacks logged in audit.log with auth_method
- [x] End-to-end callback flow verified (HA → Tools Gateway)

#### Note
Snooze re-notification scheduling deferred to Phase 8.5 (Escalation & Reliability) as it requires persistent scheduling infrastructure.

---

### Phase 8.3: Daily Digest (COMPLETE)

#### TODOs
- [x] Create HA automation `jarvis_daily_digest` (trigger: 07:00)
- [x] Track notification count via `input_number.jarvis_notification_count`
- [x] Increment on new notification, decrement on ACK/APPROVE/DENY
- [x] Send single digest push with summary
- [x] Add "Mark All Read" action to clear inbox
- [x] Create `jarvis_clear_all_notifications` automation

#### Verification
- [x] Daily digest automation created (triggers at 07:00)
- [x] Digest shows pending notification count
- [x] Mark All Read clears counter and persistent notifications

---

### Phase 8.4: Approval Gates (COMPLETE)

#### TODOs
- [x] Add ApprovalStore class to Tools Gateway (in-memory with TTL)
- [x] Implement `request_approval` endpoint
- [x] Implement `check_approval` endpoint
- [x] Add `pending_approvals` list endpoint
- [x] Add TTL enforcement (5 min default, configurable)
- [x] Bind approval to action payload hash (SHA256)
- [x] Update `attention_callback` to handle APPROVE/DENY
- [x] APPROVE/DENY buttons via severity="approval" notifications

#### Verification
- [x] Approval request creates pending entry with unique ID
- [x] APPROVE callback updates status, check_approval returns true
- [x] DENY callback updates status, check_approval returns false
- [x] Expired approvals rejected by check_approval
- [x] Payload hash mismatch rejected by check_approval

---

### Phase 8.5: Escalation & Reliability (COMPLETE)

#### TODOs
- [x] Implement retry with backoff for notify calls (3 attempts, exponential backoff)
- [x] Implement quiet hours policy (22:00-07:00 CST, FYI suppressed)
- [x] Add rate limiting per severity (configurable per hour)
- [x] Add `/actions/reliability_status` endpoint for monitoring
- [ ] Optional: Urgent escalation (re-push if unacked) - deferred
- [ ] Optional: TTS announcement for urgent alerts - deferred

#### Configuration (Environment Variables)
| Variable | Default | Description |
|----------|---------|-------------|
| `QUIET_HOURS_START` | 22 | Start of quiet hours (24h) |
| `QUIET_HOURS_END` | 7 | End of quiet hours (24h) |
| `QUIET_HOURS_TIMEZONE` | America/Chicago | Timezone for quiet hours |
| `RATE_LIMIT_FYI` | 20 | Max FYI notifications per hour |
| `RATE_LIMIT_NEEDS_RESPONSE` | 10 | Max needs_response per hour |
| `RATE_LIMIT_URGENT` | 50 | Max urgent per hour |
| `RATE_LIMIT_APPROVAL` | 20 | Max approval per hour |
| `RETRY_MAX_ATTEMPTS` | 3 | Max retry attempts |
| `RETRY_BASE_DELAY` | 1.0 | Base delay in seconds |

#### Verification
- [x] Failed notifications retry with exponential backoff
- [x] FYI notifications suppressed during quiet hours
- [x] Rate limits enforced per severity level
- [x] Rate counts logged in audit log

---

## Phase 9: Discord Bridge

Discord as a first-class, 2-way interface for Jarvis with thread-based sessions and chat mode.

See full plan: [plans/jarvis/discord-bridge/README.md](discord-bridge/README.md)

### Phase 9.1: Basic Sessions (IN PROGRESS)

#### TODOs
- [ ] Create Discord app + bot, invite to server
- [ ] Create channel `#jarvis-ops`
- [ ] Capture IDs: guild_id, jarvis-ops channel_id, your user_id
- [x] Create discord-bridge service with Dockerfile
- [x] Implement Discord Gateway connection (discord.py)
- [x] Handle DMs, messages in `#jarvis-ops`, thread creation
- [x] Add `/discord/inbound` endpoint to Tools Gateway
- [x] Implement session store (SQLite)
- [x] Add discord-bridge to docker-compose.yml
- [ ] Deploy and test DM flow
- [ ] Deploy and test thread creation in jarvis-ops
- [ ] Verify chat mode in Jarvis-owned threads

#### Configuration (Environment Variables)
| Variable | Description |
|----------|-------------|
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `DISCORD_BRIDGE_SECRET` | HMAC secret for bridge <-> Tools Gateway |
| `DISCORD_ALLOWED_GUILDS` | Comma-separated guild IDs |
| `DISCORD_ALLOWED_CHANNELS` | Comma-separated channel IDs |
| `DISCORD_ALLOWED_USERS` | Comma-separated user IDs |
| `DISCORD_JARVIS_OPS_CHANNEL` | The jarvis-ops channel ID |

#### Acceptance Criteria
- [ ] DM works (always responds)
- [ ] @jarvis in jarvis-ops creates a thread and responds inside it
- [ ] Chat mode works inside Jarvis threads (no @ required)

---

### Phase 9.2: Projects + Pins + Summarization (NOT STARTED)

#### TODOs
- [ ] Add Project registry (projects.yaml)
- [ ] Implement `/discord/session/set_project` endpoint
- [ ] Implement `/discord/session/pin` endpoint
- [ ] Implement summarization trigger
- [ ] Implement slash commands: /jarvis project, /jarvis pin, /jarvis summarize, /jarvis reset

#### Acceptance Criteria
- [ ] Thread project binding persists and changes routing/context
- [ ] Pins affect responses
- [ ] Summary updates over time

---

### Phase 9.3: Attention + Buttons + Approvals (NOT STARTED)

#### TODOs
- [ ] Implement outbound message posting with buttons
- [ ] Implement interaction event handler (button clicks)
- [ ] Implement `/discord/notify` endpoint
- [ ] Implement `/discord/interaction` endpoint
- [ ] Integrate with existing approval store

#### Acceptance Criteria
- [ ] Jarvis can request approval, user clicks Approve, Jarvis continues
- [ ] Jarvis can send needs_response alerts to Discord

---

### Phase 9.4: Operational Hardening (NOT STARTED)

#### TODOs
- [ ] Rate limiting and batching
- [ ] Dedupe with stable keys
- [ ] Health checks + restart policies
- [ ] Backoff/retry for Discord rate limits

#### Acceptance Criteria
- [ ] No spam storms
- [ ] Stable long-running behavior

---

## Operations Guide

### Source of Truth

All configuration files are stored in the infrastructure repo and deployed to their respective hosts:

| Component | Source (Repo) | Deployed Location | Host |
|-----------|---------------|-------------------|------|
| Docker Compose | `jarvis/docker-compose.yml` | `/opt/jarvis/docker-compose.yml` | PCT 121 |
| LibreChat Config | `jarvis/librechat.yaml` | `/opt/jarvis/librechat.yaml` | PCT 121 |
| Agent Definitions | `jarvis/agents/agents.yaml` | `/opt/jarvis/agents/agents.yaml` | PCT 121 |
| AGiXT Extension | `jarvis/agixt-extensions/tools_gateway.py` | `/opt/jarvis/agixt-extensions/tools_gateway.py` | PCT 121 |
| Tools Gateway | `jarvis/tools-gateway/main.py` | Built into container | PCT 121 |
| Discord Session Store | `jarvis/tools-gateway/discord_session.py` | Built into container | PCT 121 |
| Discord Bridge | `jarvis/discord-bridge/` | Built into container | PCT 121 |
| Projects Config | `jarvis/projects.yaml` | `/opt/jarvis/projects.yaml` | PCT 121 |
| HA Automations | `jarvis/homeassistant/jarvis_attention.yaml` | `/root/homeassistant/packages/jarvis_attention.yaml` | VM 101 |
| Environment | N/A (secrets) | `/opt/jarvis/.env` | PCT 121 |

### Updating LibreChat Configuration

```bash
# 1. Edit source file
vim /root/repos/infrastructure/jarvis/librechat.yaml

# 2. Push to PCT 121
pct push 121 /root/repos/infrastructure/jarvis/librechat.yaml /opt/jarvis/librechat.yaml

# 3. Restart LibreChat
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose restart librechat"
```

### Updating AGiXT Agents

```bash
# 1. Edit agent definitions
vim /root/repos/infrastructure/jarvis/agents/agents.yaml

# 2. Push to PCT 121
pct push 121 /root/repos/infrastructure/jarvis/agents/agents.yaml /opt/jarvis/agents/agents.yaml

# 3. Re-provision agents (updates personas)
pct exec 121 -- bash -c 'cd /opt/jarvis && export $(grep -v "^#" .env | xargs) && python3 agents/provision.py'

# 4. To update agent commands/extensions, use the API:
# PUT /v1/agent/{agent_id}/commands with {"commands": {"Command Name": true}}
```

### Updating AGiXT Extension (tools_gateway.py)

```bash
# 1. Edit extension
vim /root/repos/infrastructure/jarvis/agixt-extensions/tools_gateway.py

# 2. Push to PCT 121
pct push 121 /root/repos/infrastructure/jarvis/agixt-extensions/tools_gateway.py /opt/jarvis/agixt-extensions/tools_gateway.py

# 3. Clear AGiXT caches and restart
pct exec 121 -- docker exec agixt rm -f /agixt/.extensions_cache.json /agixt/models/extension_metadata_cache.json
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose restart agixt"
```

### Updating Tools Gateway

```bash
# 1. Edit source files
vim /root/repos/infrastructure/jarvis/tools-gateway/main.py
vim /root/repos/infrastructure/jarvis/tools-gateway/actions.yaml

# 2. Push to PCT 121
pct push 121 /root/repos/infrastructure/jarvis/tools-gateway/main.py /opt/jarvis/tools-gateway/main.py
pct push 121 /root/repos/infrastructure/jarvis/tools-gateway/actions.yaml /opt/jarvis/tools-gateway/actions.yaml

# 3. Rebuild and restart
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose build tools-gateway && docker compose up -d tools-gateway"
```

### Updating Home Assistant Automations

```bash
# 1. Edit automation file
vim /root/repos/infrastructure/jarvis/homeassistant/jarvis_attention.yaml

# 2. Mount VM 101 disk and copy (requires VM to be stopped or use alternative method)
# Option A: Direct copy if disk is mounted
cp /root/repos/infrastructure/jarvis/homeassistant/jarvis_attention.yaml /mnt/vm101-disk/root/homeassistant/packages/

# Option B: SSH to VM (if running)
scp /root/repos/infrastructure/jarvis/homeassistant/jarvis_attention.yaml root@192.168.1.61:/root/homeassistant/packages/

# 3. Reload automations in HA
# Via HA UI: Developer Tools → YAML → Reload Automations
# Or via API: POST http://192.168.1.61:8123/api/services/automation/reload
```

### Updating docker-compose.yml

```bash
# 1. Edit compose file
vim /root/repos/infrastructure/jarvis/docker-compose.yml

# 2. Push to PCT 121
pct push 121 /root/repos/infrastructure/jarvis/docker-compose.yml /opt/jarvis/docker-compose.yml

# 3. Apply changes (will recreate containers as needed)
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose up -d"
```

### Viewing Logs

```bash
# All services
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose logs -f"

# Specific service
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose logs -f tools-gateway"
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose logs -f agixt"
pct exec 121 -- bash -c "cd /opt/jarvis && docker compose logs -f librechat"

# Tools Gateway audit log
pct exec 121 -- docker exec tools-gateway cat /app/logs/audit.log
```

### Key Agent IDs (for API calls)

| Agent | ID |
|-------|-----|
| Jarvis-Router | `6092f523-d3d8-48d1-8650-921c3be8beab` |
| InfraAgent | `07b58cb2-fd8c-4a57-8539-279982661fd3` |
| OpsAgent | `bfa90790-cb96-4c92-bb9c-f613eb0597db` |

---

## Resource Summary

| Component | Container | RAM | CPU | Disk |
|-----------|-----------|-----|-----|------|
| Jarvis Stack | PCT 121 | 16 GiB | 4 | 50 GiB |
| Postgres | PCT 114 | (existing) | - | +10 GiB for vectors |
| Redis | PCT 116 | (existing) | - | - |

---

## Security Checklist

- [ ] No shell execution from agent
- [ ] Tools Gateway allowlist enforced
- [ ] API keys stored in secrets (not in repo)
- [ ] Audit logging enabled
- [ ] Network policies restrict service communication
- [ ] Authelia protects web UI (if public)
- [ ] Twilio webhook validates signatures

---

## Files Created

```
infrastructure/
├── plans/jarvis/
│   ├── README.md          # This file
│   ├── adr/               # Architecture Decision Records
│   └── discord-bridge/
│       └── README.md      # Discord Bridge implementation plan
├── pct/
│   └── 121-jarvis.conf    # Container spec
└── jarvis/
    ├── docker-compose.yml
    ├── .env.example
    ├── librechat.yaml
    ├── projects.yaml          # Project definitions for sessions
    ├── agixt-extensions/
    │   └── tools_gateway.py   # AGiXT extension for Tools Gateway
    ├── agents/
    │   ├── agents.yaml        # Role-based agent definitions
    │   └── provision.py       # Agent provisioning script
    ├── discord-bridge/        # Discord Gateway client (Phase 9)
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   ├── main.py
    │   └── config.py
    ├── homeassistant/
    │   └── jarvis_attention.yaml  # HA automations for iOS attention
    ├── rag-ingestion/
    ├── tools-gateway/
    │   ├── main.py            # Extended with Discord endpoints
    │   └── discord_session.py # SQLite session store
    └── whatsapp-bridge/
```

---

## Changelog

| Date | Phase | Change |
|------|-------|--------|
| 2026-01-09 | 0 | Initial project plan created |
| 2026-01-09 | 0 | ADR-001 architecture decisions documented |
| 2026-01-09 | 1 | PCT 121 created (Ubuntu 22.04, 16GiB/6CPU/50GiB) |
| 2026-01-09 | 1 | Docker 29.1.4 + Compose 5.0.1 installed |
| 2026-01-09 | 2 | LibreChat stack deployed (LibreChat, MongoDB, Meilisearch, RAG API) |
| 2026-01-09 | 2 | pgvector 0.8.1 installed on PCT 114, librechat_rag database created |
| 2026-01-09 | 2 | LibreChat accessible at http://192.168.1.117:3080 |
| 2026-01-09 | 6 | NGINX + TLS configured for https://chat.corbello.io |
| 2026-01-09 | 3 | AGiXT API deployed at https://jarvis.corbello.io |
| 2026-01-09 | 3 | AGiXT UI disabled (upstream build issue) - LibreChat is primary UI |
| 2026-01-09 | 4 | RAG ingestion pipeline created, 29 chunks from infrastructure docs ingested |
| 2026-01-09 | 5 | Tools Gateway deployed with read_file, webhook, search_docs, github_issue actions |
| 2026-01-09 | 3 | LibreChat → AGiXT integration via custom endpoint (/v1/chat/completions) |
| 2026-01-11 | 8.1 | iOS Attention System Phase 1 complete - push notifications via Home Assistant |
| 2026-01-11 | 8.1 | Tools Gateway: notify_attention + attention_callback endpoints |
| 2026-01-11 | 8.1 | HA automation deployed to VM 101 (jarvis_attention.yaml) |
| 2026-01-11 | 8.1 | HMAC signing, dedupe store, severity-based routing implemented |
| 2026-01-11 | 8.2 | LAN trust for callbacks (192.168.1.x trusted without HMAC) |
| 2026-01-11 | 8.2 | ACK/SNOOZE callbacks working end-to-end with audit logging |
| 2026-01-11 | 8.2 | iOS action buttons fixed (long-press to reveal Acknowledge/Snooze) |
| 2026-01-11 | 8.2 | Phase 8.2 complete - full callback flow verified |
| 2026-01-11 | 8.3 | Daily digest automation (07:00 trigger) |
| 2026-01-11 | 8.3 | Notification counter with increment/decrement tracking |
| 2026-01-11 | 8.3 | Mark All Read action to clear inbox |
| 2026-01-11 | 8.4 | ApprovalStore with TTL and payload hash verification |
| 2026-01-11 | 8.4 | request_approval, check_approval, pending_approvals endpoints |
| 2026-01-11 | 8.4 | Full approval flow verified (request → iOS push → APPROVE → check) |
| 2026-01-11 | 8.5 | Retry with exponential backoff for HA webhook calls |
| 2026-01-11 | 8.5 | Quiet hours policy (22:00-07:00 CST, FYI suppressed) |
| 2026-01-11 | 8.5 | Rate limiting per severity with configurable limits |
| 2026-01-11 | 8.5 | reliability_status endpoint for monitoring |
| 2026-01-11 | 8 | iOS Attention System complete - all phases implemented |
| 2026-01-11 | 3 | Created tools_gateway.py AGiXT extension for iOS notifications |
| 2026-01-11 | 3 | AGiXT extension provides: Send iOS Notification, Request/Check Approval, List Pending, Check Reliability |
| 2026-01-11 | 3 | Enabled Tools Gateway extension for Jarvis-Router (notifications + approvals) |
| 2026-01-11 | 3 | Enabled Tools Gateway extension for InfraAgent (file read + doc search) |
| 2026-01-11 | 3 | Enabled Tools Gateway extension for OpsAgent (notifications) |
| 2026-01-11 | 9.1 | Discord Bridge plan created (plans/jarvis/discord-bridge/) |
| 2026-01-11 | 9.1 | discord-bridge service created (discord.py client) |
| 2026-01-11 | 9.1 | Tools Gateway extended with Discord endpoints (/discord/inbound, /discord/notify, /discord/interaction) |
| 2026-01-11 | 9.1 | SQLite session store implemented for Discord sessions |
| 2026-01-11 | 9.1 | Projects configuration file created (projects.yaml) |
| 2026-01-11 | 9.1 | docker-compose.yml updated with discord-bridge service |
