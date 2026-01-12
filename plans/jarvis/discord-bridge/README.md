# Discord Bridge for Jarvis

Discord as a first-class, 2-way interface for Jarvis with thread-based sessions, chat mode, and full AGiXT integration.

## Overview

Add Discord support to Jarvis enabling:
- DM support (always works)
- `#jarvis-ops` channel support
- Mention-based session start: `@jarvis ...` creates/uses a thread session
- **Chat mode inside Jarvis-owned threads** (no @ required)
- Project/context binding per thread (Projects-like behavior)
- Approval/permission prompts with buttons
- Full auditability and guardrails
- Integrates with existing: LibreChat -> AGiXT -> Tools Gateway pattern

---

## Architecture

### Components

```
Discord Gateway <-> discord-bridge (new) <-> Tools Gateway (existing) <-> AGiXT
                                                    |
                                           Session Store (SQLite)
                                                    |
                                           Home Assistant (iOS push)
```

- **Discord Bridge** (new container, LAN)
  - Handles Discord Gateway events (messages, thread creation, button interactions)
  - Forwards inbound events to Tools Gateway
  - Receives outbound "notify" requests from Tools Gateway

- **Tools Gateway** (existing, extended)
  - Enforces allowlists, HMAC, rate limits, policy
  - Logs everything
  - Calls AGiXT endpoints
  - Manages session state + approvals store
  - New: `/discord/inbound`, `/discord/notify`, `/discord/interaction` endpoints

- **AGiXT** (existing)
  - Jarvis Router orchestrator agent
  - Domain agents (marketing/dev/legal/etc.)
  - Uses Tools Gateway tools (delegate, git, webhooks, etc.)

### Data Flow

**Inbound**
1. Discord message -> discord-bridge
2. discord-bridge -> Tools Gateway `/discord/inbound`
3. Tools Gateway -> AGiXT Jarvis Router `/v1/chat/completions`
4. Tools Gateway -> discord-bridge `/discord/outbound` (reply)

**Outbound (Jarvis-initiated)**
1. AGiXT calls Tools Gateway `notify_attention`
2. Tools Gateway routes to:
   - Discord (interactive alerts, approvals, needs-response), and/or
   - Home Assistant (FYI + digest)
3. discord-bridge posts message / buttons

---

## Interaction Model (Exact Rules)

### DM = Always a session
- If you DM the bot: always respond.
- DM channel ID is the session key.

### `#jarvis-ops` channel = mention triggers a session thread
In `#jarvis-ops`:
- If message contains **@jarvis**:
  - If it's *already in a thread*: use that thread's session.
  - If it's *not in a thread*: create a new thread and start a session there.

### Chat mode inside Jarvis-owned threads
Inside a thread created by Jarvis:
- Default: **Chat mode ON**
- Jarvis responds to messages from allowlisted users **without @jarvis**.
- Only within Jarvis-owned threads (not every thread).

### Allowlist boundaries
Jarvis responds only in:
- DMs
- `#jarvis-ops` (mentions only)
- Threads that are "Jarvis-owned" (chat mode)

---

## Session + Context Strategy

### Session Keys
- DM session: `discord:dm:<dm_channel_id>`
- Thread session: `discord:thread:<thread_id>`

### Context injection per turn
Tools Gateway builds the model input:
1. SYSTEM_CONTRACT (always)
2. Jarvis Router persona (always)
3. Thread "pins" (optional, small)
4. Project binding context (optional)
5. Session memory summary (short, maintained)
6. Sliding window of last N messages (10-30)
7. Current user message

### Auto-summarization policy
- Summarize when:
  - token threshold hit, OR
  - every N messages (e.g., 20)
- Keep:
  - summary
  - last N messages
- Archive older raw messages (optional)

---

## Projects / Context Groupings

Lightweight Projects model per session.

### Thread project binding
- Command: `/jarvis project set <project_id>`
- Stored on the session:
  - `active_project_id`
- A project defines:
  - default agent routing (domain agents)
  - default RAG collections (if any)
  - default git repo targets (jarvis-workspace)
  - tool allowlists (optional)

### One-off overrides (optional)
- Mention tags: `@jarvis #infra ...` overrides project for that message only.

---

## Commands and UX

### Slash commands
- `/jarvis ask <text>` - Starts/continues a session (thread in jarvis-ops, DM otherwise)
- `/jarvis project set <project_id>`
- `/jarvis project show`
- `/jarvis pin <text>` - Adds a pinned instruction to the session
- `/jarvis pins` - List pins
- `/jarvis unpin <pin_id>`
- `/jarvis summarize` - Prints current session summary
- `/jarvis reset` - Clears session summary + window
- `/jarvis mode chat|mention` - (optional; default chat for Jarvis threads)

### Message actions (buttons)
For alerts/approvals:
- Approve
- Deny
- View details (link to LibreChat / Git PR / diff)
- Snooze 30m
- Ack / Resolve

---

## Data Models

### Session
```json
{
  "session_id": "discord:thread:1234567890",
  "platform": "discord",
  "scope": "thread",
  "guild_id": "GUILD_ID",
  "channel_id": "jarvis-ops-channel-id",
  "thread_id": "1234567890",
  "owner_user_id": "OWNER_DISCORD_USER_ID",
  "allowed_user_ids": ["OWNER_DISCORD_USER_ID"],
  "chat_mode": true,
  "created_at": "2026-01-11T16:00:00Z",
  "last_activity_at": "2026-01-11T16:12:00Z",
  "active_project_id": "infra",
  "pins": [
    { "pin_id": "p1", "text": "Prefer K3s. Keep everything LAN-only.", "created_at": "..." }
  ],
  "summary": "Short rolling summary of this session...",
  "message_window": [
    { "role": "user", "content": "..." },
    { "role": "assistant", "content": "..." }
  ]
}
```

### Project
```json
{
  "project_id": "infra",
  "name": "Homelab Infrastructure",
  "description": "K3s, Proxmox, Traefik, Auth, internal services",
  "default_agents": ["InfraAgent", "OpsAgent", "SecurityAgent"],
  "rag_collections": ["infrastructure_docs"],
  "git_targets": ["jarvis-workspace"],
  "tool_policy": {
    "allow_git_stage": true,
    "allow_webhooks": "allowlisted_only",
    "approval_required": ["git_stage", "git_open_pr", "webhook_external"]
  }
}
```

### Attention / Approval Request
```json
{
  "request_id": "uuid",
  "type": "approval",
  "severity": "approval",
  "title": "Stage changes to jarvis-workspace",
  "message": "Create docs/plans/discord-bridge plan and commit to a branch.",
  "session_id": "discord:thread:123...",
  "payload_hash": "sha256-of-bound-action",
  "expires_at": "2026-01-11T16:20:00Z",
  "status": "pending",
  "created_by": "AGiXT:Jarvis",
  "created_at": "..."
}
```

### Audit Log Event
```json
{
  "event_id": "uuid",
  "timestamp": "ISO",
  "actor": { "type": "user", "id": "DISCORD_USER_ID" },
  "source": { "platform": "discord", "session_id": "discord:thread:..." },
  "action": "discord_inbound_message",
  "details": { "message_id": "...", "content_hash": "...", "len": 123 },
  "result": { "status": "ok", "latency_ms": 840 }
}
```

---

## Tools Gateway APIs (Contracts)

### Inbound from discord-bridge

**POST** `/discord/inbound`

* Validates: allowlisted guild/channel/user, HMAC, nonce, rate limit
* Resolves session_id
* Decides whether to respond (based on rules)
* Calls AGiXT Jarvis Router
* Returns reply instructions to discord-bridge

Request:
```json
{
  "guild_id": "...",
  "channel_id": "...",
  "thread_id": null,
  "dm_channel_id": null,
  "author_user_id": "...",
  "message_id": "...",
  "content": "...",
  "mentions_bot": true,
  "is_thread": false,
  "timestamp": "..."
}
```

Response:
```json
{
  "should_reply": true,
  "reply_target": { "type": "thread", "thread_id": "123..." },
  "reply_text": "...",
  "create_thread": { "name": "Jarvis: topic", "auto_archive_duration": 1440 }
}
```

### Outbound to discord-bridge (Jarvis-initiated)

**POST** `/discord/notify`

* Tools Gateway decides routing (DM vs channel vs thread)
* discord-bridge posts with buttons

Request:
```json
{
  "target": { "type": "dm", "user_id": "..." },
  "severity": "needs_response",
  "title": "Jarvis is blocked",
  "message": "Which project should I bind this thread to? infra | legal | a2g",
  "session_id": "discord:thread:123...",
  "buttons": [
    { "id": "SET_PROJECT_INFRA", "label": "infra" },
    { "id": "SET_PROJECT_LEGAL", "label": "legal" },
    { "id": "SET_PROJECT_A2G", "label": "a2g" }
  ],
  "details_url": "https://chat.corbello.io/..."
}
```

### Interaction callback (buttons)

**POST** `/discord/interaction`

* Used for Approve/Deny/Ack/Snooze/SetProject actions
* Updates session/request state and (if approval) releases the gate

Request:
```json
{
  "interaction_id": "...",
  "button_id": "APPROVE",
  "request_id": "uuid-or-null",
  "session_id": "discord:thread:123...",
  "user_id": "...",
  "message_id": "...",
  "timestamp": "..."
}
```

---

## AGiXT Integration

### Treat Discord as another "front door"
LibreChat and Discord both feed the same Jarvis Router.
**Do not** duplicate brains in the bridge.

### Router "team awareness" and delegation
Your Router should:
* call `list_agents` (Tools Gateway) to get roster
* call `delegate_agent` (Tools Gateway) when needed
* keep responses unified

### Required Tools available to Router (via Tools Gateway)
* `list_agents`
* `delegate_agent`
* `notify_attention` (routes to Discord + HA)
* `request_approval` / `approval_status` / `approval_callback`
* `git_stage` / `git_open_pr` (jarvis-workspace)

---

## Implementation Phases

### Phase 1: Discord Bridge + Basic Sessions (CURRENT)

#### TODOs (Discord Setup)
- [ ] Create Discord app + bot, invite to server
- [ ] Create channel `#jarvis-ops`
- [ ] Capture IDs: guild_id, jarvis-ops channel_id, your user_id

#### TODOs (discord-bridge service)
- [ ] Create discord-bridge directory with Dockerfile
- [ ] Connect to Discord Gateway (discord.py or similar)
- [ ] Handle:
  - [ ] DMs
  - [ ] messages in `#jarvis-ops`
  - [ ] thread creation API call
- [ ] If message contains @jarvis in jarvis-ops and not in thread:
  - [ ] create thread
  - [ ] forward to Tools Gateway with thread_id
- [ ] If message is in Jarvis-owned thread with chat_mode=true:
  - [ ] forward without requiring @jarvis

#### TODOs (Tools Gateway)
- [ ] Implement `/discord/inbound`:
  - [ ] allowlist checks
  - [ ] session store (create/lookup)
  - [ ] "should I respond" rules
  - [ ] call AGiXT Jarvis Router
- [ ] Add session persistence (SQLite)
- [ ] Add audit logs for Discord events

**Acceptance Criteria**
- [ ] DM works
- [ ] @jarvis in jarvis-ops creates a thread and responds inside it
- [ ] chat mode works inside Jarvis threads

---

### Phase 2: Projects + Pins + Summarization

#### TODOs (Tools Gateway)
- [ ] Add Project registry (static YAML/JSON file initially)
- [ ] Add endpoints:
  - [ ] `/discord/session/set_project`
  - [ ] `/discord/session/pin`
  - [ ] `/discord/session/reset`
  - [ ] `/discord/session/summarize`
- [ ] Implement summarization trigger (message count or token estimate)

#### TODOs (discord-bridge)
- [ ] Implement slash commands:
  - [ ] /jarvis project set
  - [ ] /jarvis pin
  - [ ] /jarvis summarize
  - [ ] /jarvis reset

**Acceptance Criteria**
- [ ] Thread project binding persists and changes routing/context
- [ ] Pins affect responses
- [ ] Summary updates over time

---

### Phase 3: Attention + Buttons + Approvals

#### TODOs (discord-bridge)
- [ ] Implement outbound message posting with buttons (interactions)
- [ ] Implement interaction event handler:
  - [ ] button_id mapping
  - [ ] callback to Tools Gateway `/discord/interaction`
  - [ ] ephemeral confirmations where appropriate

#### TODOs (Tools Gateway)
- [ ] Implement `/discord/notify` and `/discord/interaction`
- [ ] Build approval store + TTL + payload binding hash (extends existing)
- [ ] Integrate approvals with sensitive tools (git_stage, git_open_pr, external webhooks)

**Acceptance Criteria**
- [ ] Jarvis can request approval, you click Approve, Jarvis continues
- [ ] Jarvis can "needs_response" ping you and you respond in-thread

---

### Phase 4: Operational Hardening

#### TODOs
- [ ] Rate limiting and batching (especially FYI)
- [ ] Dedupe with stable keys (edit message instead of spamming)
- [ ] Quiet hours policy (recommend: HA handles FYI/digest; Discord for interactive)
- [ ] Health checks + restart policies
- [ ] Backoff/retry for Discord rate limits

**Acceptance Criteria**
- [ ] No spam storms
- [ ] Stable long-running behavior

---

## Deployment Details

### Container placement
- Run `discord-bridge` on **PCT 121** alongside AGiXT/Tools Gateway (same Docker network).

### Secrets (Environment Variables)
| Variable | Description |
|----------|-------------|
| `DISCORD_BOT_TOKEN` | Discord bot token (bridge only) |
| `DISCORD_BRIDGE_SECRET` | HMAC secret for bridge <-> Tools Gateway |
| `DISCORD_ALLOWED_GUILDS` | Comma-separated guild IDs |
| `DISCORD_ALLOWED_CHANNELS` | Comma-separated channel IDs (jarvis-ops + any others) |
| `DISCORD_ALLOWED_USERS` | Comma-separated user IDs (you + admins) |
| `DISCORD_JARVIS_OPS_CHANNEL` | The jarvis-ops channel ID |

### Networking
- No inbound exposure needed; bridge maintains outbound connection to Discord.
- Internal communication via `jarvis-net` Docker network.

---

## Recommended Defaults

- `#jarvis-ops` is the only channel where mentions create threads
- Jarvis threads default to **chat mode ON**
- DM always works
- Projects start with: `infra`, `legal`, `a2g`, `general`
- Approvals required for: `git_stage`, `git_open_pr`, external webhooks

---

## Files to Create

```
infrastructure/
├── plans/jarvis/discord-bridge/
│   └── README.md              # This file
└── jarvis/
    ├── discord-bridge/
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   ├── main.py            # Discord Gateway client
    │   └── config.py          # Configuration
    ├── tools-gateway/
    │   └── main.py            # Extended with Discord endpoints
    └── projects.yaml          # Project definitions
```

---

## Changelog

| Date | Phase | Change |
|------|-------|--------|
| 2026-01-11 | 0 | Initial plan created |
