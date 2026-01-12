# Jarvis AI Assistant - Architecture

LAN-hosted AI assistant with multi-model chat interface and autonomous agent capabilities.

## Overview

Jarvis is a self-hosted AI assistant running on the Cortech homelab cluster. It provides a web-based chat interface with access to multiple LLM providers, document retrieval (RAG), and a controlled set of tools for automation.

## System Architecture

```
                                 Internet
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PCT 100 (proxy)                                      │
│                     NGINX + Let's Encrypt                                   │
│  ┌─────────────────────────────┐  ┌─────────────────────────────┐          │
│  │  chat.corbello.io :443      │  │  jarvis.corbello.io :443    │          │
│  └──────────────┬──────────────┘  └──────────────┬──────────────┘          │
└─────────────────┼────────────────────────────────┼──────────────────────────┘
                  │                                │
                  ▼                                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PCT 121 (jarvis)                                     │
│                    192.168.1.117 - Docker Compose                           │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         jarvis_jarvis-net                            │   │
│  │                                                                      │   │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐           │   │
│  │  │  LibreChat   │───▶│    AGiXT     │───▶│    Tools     │           │   │
│  │  │   :3080      │    │    :7437     │    │   Gateway    │           │   │
│  │  │              │    │              │    │    :8080     │           │   │
│  │  │  Chat UI     │    │ Agent Engine │    │  Safe Actions│           │   │
│  │  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘           │   │
│  │         │                   │                   │                    │   │
│  │         ▼                   ▼                   ▼                    │   │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐           │   │
│  │  │   MongoDB    │    │  AGiXT DB    │    │   RAG API    │           │   │
│  │  │   :27017     │    │  (postgres)  │    │    :8000     │           │   │
│  │  └──────────────┘    └──────────────┘    └──────┬───────┘           │   │
│  │                                                 │                    │   │
│  │  ┌──────────────┐                               │                    │   │
│  │  │ Meilisearch  │                               │                    │   │
│  │  │   :7700      │                               │                    │   │
│  │  └──────────────┘                               │                    │   │
│  │                                                 │                    │   │
│  └─────────────────────────────────────────────────┼────────────────────┘   │
└─────────────────────────────────────────────────────┼───────────────────────┘
                                                      │
                  ┌───────────────────────────────────┘
                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PCT 114 (postgres)                                   │
│                    PostgreSQL 15 + pgvector 0.8.1                           │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Database: librechat_rag                                              │  │
│  │  - Vector embeddings (1536 dimensions, OpenAI)                        │  │
│  │  - Infrastructure docs collection (29 chunks)                         │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### LibreChat (Frontend)
- **Purpose**: Multi-user chat interface with authentication
- **Image**: `ghcr.io/danny-avila/librechat:latest`
- **Port**: 3080
- **URL**: https://chat.corbello.io
- **Features**:
  - User registration and login
  - Conversation history and search
  - File uploads
  - Multiple endpoint support (OpenAI, Anthropic, Jarvis Agent)
  - RAG document retrieval integration

### AGiXT (Agent Engine)
- **Purpose**: Autonomous agent execution with tool orchestration
- **Image**: `joshxt/agixt:main`
- **Port**: 7437
- **URL**: https://jarvis.corbello.io (API only)
- **Features**:
  - OpenAI-compatible API (`/v1/chat/completions`)
  - Agent memory and context
  - Extension system for capabilities
  - Multi-provider LLM support

### Tools Gateway (Safe Actions API)
- **Purpose**: Allowlisted, audited actions for agent automation
- **Image**: Custom (FastAPI)
- **Port**: 8080
- **Features**:
  - API key authentication
  - Audit logging of all actions
  - Rate limiting
  - Strict input validation

### RAG API (Document Retrieval)
- **Purpose**: Semantic search over ingested documents
- **Image**: `ghcr.io/danny-avila/librechat-rag-api-dev-lite:latest`
- **Port**: 8000 (internal)
- **Backend**: PostgreSQL + pgvector on PCT 114

### Supporting Services
| Service | Purpose | Port |
|---------|---------|------|
| MongoDB | LibreChat conversations, users | 27017 |
| Meilisearch | Full-text search | 7700 |
| AGiXT DB | Agent state, memory | 5432 |

## Role-Based Agents

The system provides specialized agent endpoints optimized for different tasks:

| Agent | Purpose | Models | Best For |
|-------|---------|--------|----------|
| **Jarvis** | Primary coordinator | GPT-5.2, Claude Sonnet/Opus | General assistance, task routing |
| **Research Agent** | Information gathering | Claude Sonnet/Opus | Web research, RAG queries, summarization |
| **Infra Agent** | Infrastructure docs | GPT-5.2, GPT-5.2-pro | File reading, config analysis |
| **Planner Agent** | Complex reasoning | GPT-5.2-pro only | Architecture decisions, risk analysis |
| **Writer Agent** | Documentation | Claude Sonnet/Opus | Markdown, specs, configs |

### Model Stratification

| Task Type | Recommended Model | Rationale |
|-----------|-------------------|-----------|
| Complex reasoning | GPT-5.2-pro | Best logical inference |
| Summarization | Claude Sonnet | Strong at synthesis |
| Quick/cheap steps | GPT-5.2 | Cost-efficient |
| RAG synthesis | Claude Opus | Long context window |
| Code generation | GPT-5.2-pro | Precise output |
| Documentation | Claude Sonnet | Natural prose |

## Available Models

### Via Role-Based Endpoints
Routes through AGiXT for agent capabilities:
- `claude-sonnet-4-5-20250929`
- `claude-opus-4-5-20251101`
- `gpt-5.2`
- `gpt-5.2-pro`

### Direct Provider Access
Standard API calls without agent features:
- **OpenAI**: gpt-4o, gpt-4o-mini, gpt-4-turbo, etc.
- **Anthropic**: claude-3-5-sonnet, claude-3-opus, claude-3-haiku, etc.

## Capabilities

### Chat Interface
- Multi-turn conversations with context
- Model selection per conversation
- File attachments (images, documents)
- Conversation search and export
- User accounts with conversation history

### Agent Execution (via AGiXT)
- Autonomous task planning and execution
- Tool use and function calling
- Memory persistence across sessions
- Chain-of-thought reasoning

### Document Retrieval (RAG)
- Semantic search over ingested documents
- Source citations with file paths
- Currently indexed:
  - `/root/repos/infrastructure/docs/`
  - `/root/repos/infrastructure/plans/`

### Tools Gateway Actions

| Action | Description | Restrictions |
|--------|-------------|--------------|
| `notify_attention` | Send push notification via Home Assistant | Severity-based routing |
| `attention_callback` | Receive user action callbacks from HA | LAN trusted (192.168.1.x) |
| `request_approval` | Create approval gate for sensitive action | 5 min TTL default |
| `check_approval` | Verify if action was approved | Payload hash verified |
| `pending_approvals` | List all pending approval requests | API key required |
| `reliability_status` | Get quiet hours and rate limit status | API key required |
| `read_file` | Read file contents | Allowlisted paths only |
| `search_docs` | RAG semantic search | infrastructure_docs collection |
| `webhook` | Call external webhooks | Allowlisted URLs only |
| `github_issue` | Create GitHub issues | Allowlisted repos only |
| `proxmox_status` | Cluster status (planned) | Read-only |

### Attention System (iOS Push Notifications)

Jarvis can proactively contact you via push notifications through Home Assistant:

```
Jarvis Agent → Tools Gateway → Home Assistant → iOS Push
                    ↑                  ↓
              Audit Log          User Action (Ack/Snooze/Approve)
                    ↑                  ↓
              Callback ←───────────────┘
```

#### Severity Levels

| Severity | Use Case | Push Behavior | Actions |
|----------|----------|---------------|---------|
| `fyi` | Informational updates | Normal | Open Chat, Acknowledge |
| `needs_response` | Jarvis needs input | Time-sensitive | Open Chat, Acknowledge, Snooze 30m |
| `urgent` | Critical alerts | Critical (sound, bypasses DND) | Open Chat, Acknowledge |
| `approval` | Permission gates | Time-sensitive | Approve, Deny, Details |

#### Attention Item Fields

```json
{
  "severity": "fyi|needs_response|urgent|approval",
  "title": "Short title (max 100 chars)",
  "message": "Body text (1-3 lines, max 500 chars)",
  "details_url": "https://chat.corbello.io/c/conversation-id",
  "dedupe_key": "unique_key_for_deduplication",
  "request_id": "optional - for approval gates",
  "expires_at": "optional - ISO timestamp for approval expiry"
}
```

#### Dedupe Keys (Examples)
- `rag_ingest_complete:<date>`
- `proxmox_disk_warn:<node>`
- `scheduled_task_failed:<task_name>`
- `proposal_ready:<proposal_id>`

## System Contract

All Jarvis agents operate under a global policy defined in `SYSTEM_CONTRACT.md`. This contract establishes:

### Core Principles
1. **Safety over capability** - Prefer read-only and reversible actions
2. **Truthfulness** - Never fabricate tool results or citations
3. **Least privilege** - Use minimum tools required
4. **Auditability** - All actions traceable to user intent

### Confirmation Gates
Explicit user approval required for:
- Creating/modifying/deleting external data
- Infrastructure changes (even read-only if sensitive)
- External notifications or API calls
- High-cost operations

### Knowledge Priority
1. RAG results (internal docs)
2. Allowlisted file reads
3. Tool outputs
4. Internet research (last resort)

See `/root/repos/infrastructure/jarvis/SYSTEM_CONTRACT.md` for full policy.

## Security Model

### Network Isolation
- All services run on internal Docker network (`jarvis_jarvis-net`)
- Only LibreChat (3080), AGiXT (7437), and Tools Gateway (8080) exposed
- External access only via NGINX reverse proxy with TLS

### Authentication
- **LibreChat**: Email/password with JWT sessions
- **AGiXT API**: API key (`X-API-Key` header)
- **Tools Gateway**: API key (`X-API-Key` header)

### Agent Restrictions
- No Docker socket access (prevents container escape)
- No shell execution capability
- File access restricted to allowlisted paths
- Webhook calls restricted to allowlisted URLs
- All actions logged with timestamps and inputs

### TLS/HTTPS
- Certificates via Let's Encrypt (certbot)
- Managed on PCT 100 (proxy)
- Auto-renewal configured

## Access Points

| URL | Service | Auth Required |
|-----|---------|---------------|
| https://chat.corbello.io | LibreChat UI | Yes (user account) |
| https://jarvis.corbello.io | AGiXT API | Yes (API key) |
| http://192.168.1.117:8080 | Tools Gateway | Yes (API key) |

## Infrastructure

### Container Resources (PCT 121)
| Resource | Allocation |
|----------|------------|
| CPU | 6 cores |
| RAM | 16 GiB |
| Disk | 50 GiB |
| Network | DHCP (192.168.1.117) |

### External Dependencies
| Service | Location | Purpose |
|---------|----------|---------|
| PostgreSQL + pgvector | PCT 114 | RAG embeddings |
| Redis (optional) | PCT 116 | Session caching |
| NGINX + certbot | PCT 100 | Reverse proxy, TLS |
| Home Assistant | VM 101 (192.168.1.61) | iOS push notifications, attention system |

## Scheduled Tasks

Cron-triggered agents for automated operations:

| Task | Schedule | Agent | Purpose |
|------|----------|-------|---------|
| `infra-doc-drift` | 3 AM daily | InfraAgent | Compare docs vs actual Proxmox state |
| `rag-health-check` | 4 AM daily | OpsAgent | Check vector store freshness |
| `weekly-summary` | Mon 9 AM | ResearchAgent | Git commit summary for past week |
| `backup-verify` | Sun 5 AM | OpsAgent | Verify backup freshness (disabled) |

Logs: `/var/log/jarvis/`

## Configuration Files

```
/root/repos/infrastructure/
├── jarvis/
│   ├── docker-compose.yml      # Service definitions
│   ├── librechat.yaml          # LibreChat config (role-based endpoints)
│   ├── SYSTEM_CONTRACT.md      # Global agent policy
│   ├── .env                    # Secrets (on PCT 121 only)
│   ├── agixt-extensions/
│   │   └── tools_gateway.py    # Custom extension for Tools Gateway actions
│   ├── agents/
│   │   ├── agents.yaml         # Agent role definitions
│   │   ├── provision.py        # Agent provisioning script
│   │   └── generate_api_key.py # Full-scope API key generator
│   ├── homeassistant/
│   │   └── jarvis_attention.yaml  # HA automations for attention system
│   ├── scheduler/
│   │   ├── scheduled_tasks.yaml # Cron task definitions
│   │   ├── run_task.py         # Task executor
│   │   └── crontab             # Cron schedule
│   ├── tools-gateway/
│   │   ├── main.py             # FastAPI application (includes attention endpoints)
│   │   ├── actions.yaml        # Allowlisted actions + HA config
│   │   └── Dockerfile
│   └── rag-ingestion/
│       └── ingest.py           # Document ingestion script
├── proxy/sites/
│   ├── chat.corbello.io.conf   # NGINX config
│   └── jarvis.corbello.io.conf
└── plans/jarvis/
    ├── README.md               # Project plan & TODOs
    ├── ARCHITECTURE.md         # This file
    └── adr/                    # Architecture decisions
```

## Data Flow

### User Chat Request
```
User → chat.corbello.io → NGINX (TLS) → LibreChat
    → [If Jarvis Agent endpoint selected]
    → AGiXT /v1/chat/completions → LLM Provider → Response
    → LibreChat → User
```

### RAG Query
```
LibreChat → RAG API /query
    → Generate embedding (OpenAI)
    → pgvector similarity search (PCT 114)
    → Return relevant chunks with sources
    → LibreChat injects context → LLM
```

### Tool Execution (via AGiXT Extension)
```
User prompt → AGiXT → Tools Gateway Extension (tools_gateway.py)
    → Extension makes HTTP request to Tools Gateway
    → Tools Gateway /actions/{action}
    → Validate API key
    → Check allowlist
    → Execute action
    → Log to audit.log
    → Return result → Extension → AGiXT → User
```

**Enabled Extensions per Agent:**
| Agent | Tools Gateway Commands |
|-------|----------------------|
| Jarvis-Router | Send iOS Notification, Request/Check Approval, List Pending, Check Reliability |
| InfraAgent | Read Allowlisted File, Search Documents |
| OpsAgent | Send iOS Notification, Check Reliability Status |

### Attention Notification
```
Jarvis Agent → Tools Gateway /actions/notify_attention
    → Validate API key
    → Check dedupe (suppress if duplicate)
    → Sign payload (HMAC-SHA256)
    → POST to Home Assistant webhook
    → HA automation triggers iOS push
    → User taps action button
    → HA calls Tools Gateway /actions/attention_callback
    → Log action to audit.log
```

## Extending the System

### Adding New Documents to RAG
```bash
# On PCT 121
cd /opt/jarvis/rag-ingestion
python ingest.py --path /path/to/docs
```

### Adding New Tools Gateway Actions
1. Add action handler in `tools-gateway/main.py`
2. Update `actions.yaml` with allowlist entries
3. Rebuild: `docker compose build tools-gateway`
4. Restart: `docker compose up -d tools-gateway`

### Creating AGiXT Agents
Access https://jarvis.corbello.io with API key to:
- Create agent personas
- Configure extensions
- Set up memory collections
- Define command chains

---

*Last updated: 2026-01-11*
