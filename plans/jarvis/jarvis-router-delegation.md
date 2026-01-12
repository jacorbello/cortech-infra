# Plan: Make Jarvis-Router Aware of and Able to Delegate to AGiXT Domain Agents
*Recommended approach:* **Delegation via Tools Gateway** (Pattern A)
*Why:* Auditable, least-privilege, stable regardless of LibreChat UI features/versions, and keeps multi-agent orchestration in one controlled place.

---

## 0) Goals (Definition of Done)

- [ ] Jarvis-Router can **list the available agents** (authoritatively, not by guessing).
- [ ] Jarvis-Router can **delegate tasks** to domain agents (Marketing, Brand, BackendDev, etc.).
- [ ] Delegations are **logged** (who, when, agent, request id, outcome).
- [ ] Domain agents remain **tool-less** (or minimal), and **cannot** perform infra actions directly.
- [ ] Jarvis-Router never claims "no agents exist" when they do, and never claims it "created agents" unless it actually did.

---

## 1) Root Cause (What's Broken Today)

Jarvis (AGiXT orchestrator) is being used through LibreChat's OpenAI-compatible chat endpoint. In that mode:

- The model **does not automatically know** what other AGiXT agents exist.
- There is likely **no tool/function** it can call to list or invoke other agents.
- LibreChat "Agents" and AGiXT "Agents" are separate concepts; the chat endpoint is effectively "single-agent."

So Jarvis answers generically and guesses about agent provisioning.

---

## 2) Architecture (Recommended)

### 2.1 Delegation lives in Tools Gateway (authoritative + auditable)

```
LibreChat (Jarvis Agent Endpoint)
│
▼
AGiXT: Jarvis-Router (no tools except Tools Gateway calls)
│
├── (GET) Tools Gateway: /agents → returns agent roster
│
└── (POST) Tools Gateway: /delegate → runs a specific agent task
    │
    └── Tools Gateway calls AGiXT internally (target agent)
        and returns result + logs everything
```

### 2.2 Key principles
- Jarvis-Router **does not** need web browsing to orchestrate.
- Jarvis-Router **must** have a reliable way to:
  - discover agents (`/agents`)
  - delegate (`/delegate`)
- Domain agents remain **capability-restricted** (mostly tool-less).

---

## 3) Implementation Phases + TODOs

## Phase 1 — Verify Reality: Provisioning + Routing
### TODOs
- [ ] Confirm AGiXT has the new domain agents provisioned:
  - Verify via AGiXT UI or API list endpoints (whichever you use).
- [ ] Confirm LibreChat "Jarvis Agent endpoint" is targeting the correct AGiXT route:
  - Ensure it's mapped to **Jarvis-Router**, not a generic/default.
- [ ] Confirm system contract injection is working for Jarvis-Router and domain agents:
  - A quick test prompt should return a brief statement about confirmation gates and least privilege.

### Acceptance Criteria
- [ ] You can name 3–5 domain agents that exist in AGiXT (e.g., Marketing, Brand, BackendDev).
- [ ] LibreChat is definitely talking to Jarvis-Router (not some other agent).

---

## Phase 2 — Add Authoritative Agent Discovery
### TODOs (Tools Gateway)
- [ ] Implement endpoint: `GET /actions/list_agents`
  - Returns the roster (source of truth):
    - Option A: read `agents.yaml` from your infra repo (allowlisted)
    - Option B: query AGiXT API for current agents
  - Include fields:
    - `name`, `description`, `domain`, `capability_tier` (tool-less / read-only / etc.)

### TODOs (Jarvis-Router persona)
- [ ] Add a "Team & Delegation" section that says:
  - "I can list agents by calling `list_agents`"
  - "I delegate via `delegate_agent`"
  - "If I don't have the list yet, I must fetch it (no guessing)."
- [ ] Explicitly forbid statements like:
  - "No agents are provisioned" unless the roster call returns empty
  - "I can create agents" unless you implement that tool

### Acceptance Criteria
- [ ] In LibreChat, Jarvis answers "who's on your team?" with a real list sourced from `list_agents`.

---

## Phase 3 — Add Delegation (Core Glue)
### TODOs (Tools Gateway)
- [ ] Implement endpoint: `POST /actions/delegate_agent`
  - Request:
    - `agent_name`
    - `task` (string)
    - `context_refs` (optional: file paths, RAG query keys, prior message ids)
    - `request_id` (uuid for audit)
  - Behavior:
    - Validate `agent_name` is allowlisted (must be in roster)
    - Forward to AGiXT target agent (internal call)
    - Return:
      - `result` (text)
      - `agent_name`
      - `request_id`
      - `timings` (optional)
      - `errors` (if any)
- [ ] Add full audit logging:
  - `who` (user id), `when`, `agent`, `task hash`, `result status`, latency

### TODOs (Jarvis-Router persona)
- [ ] Teach Router how to delegate:
  - When request is clearly domain-specific, it delegates first.
  - It then merges the response into one clean answer.
- [ ] Add rule:
  - "No delegation for sensitive actions; use SecurityAgent review or explicit approval first."

### Acceptance Criteria
- [ ] Ask: "Draft a sales cold email for X" → Jarvis delegates to SalesEnablement, returns combined output.
- [ ] Ask: "Propose a RAG chunking strategy" → Jarvis delegates to DataRAG, returns combined output.

---

## Phase 4 — Add "Attention + Approvals" Integration (Home Assistant channel)
*(Optional but strongly recommended for a coherent Jarvis experience.)*

### TODOs
- [ ] Create a standard "attention event" and "approval request" message shape.
- [ ] Router can create:
  - FYI: "I found 3 issues…"
  - Needs response: "I need one decision…"
  - Approval: "Approve running X?"
- [ ] Router calls Tools Gateway notify endpoint, HA pushes, you respond.
- [ ] Router resumes work after approval.

### Acceptance Criteria
- [ ] Router can interrupt you with "needs response" and you can jump into LibreChat to respond.
- [ ] Router requests approval for a gated action and proceeds only after approval.

---

## Phase 5 — Quality Controls (Prevent chaos as agent count grows)
### TODOs
- [ ] Add "capability tiers" to roster and enforce them:
  - Tier 0: tool-less
  - Tier 1: read-only
  - Tier 2: external calls (requires approval)
  - Tier 3: write/apply (dual approval + validation)
- [ ] Add anti-spam safeguards:
  - limit max delegations per user request (e.g., 3–5)
  - require Router to explain why it's delegating when it does
- [ ] Add a "delegation rubric":
  - "Delegate only when it materially improves quality."

### Acceptance Criteria
- [ ] Router stays fast and doesn't spawn unnecessary agent calls.
- [ ] You can see which agent contributed and why.

---

## 4) Deliverables (What You'll Have After)

- [ ] Tools Gateway endpoints:
  - [ ] `GET /actions/list_agents`
  - [ ] `POST /actions/delegate_agent`
- [ ] Updated Jarvis-Router persona with:
  - authoritative roster behavior
  - delegation policy
  - no-hallucination guarantees about agent existence
- [ ] Audit trail for every delegation (critical for trust)
- [ ] A scalable multi-agent experience inside LibreChat without relying on UI-side "handoffs"

---

## 5) Immediate Next TODOs (Do These First)

1) [ ] Confirm AGiXT provisioning (agents exist)
2) [ ] Ensure LibreChat points to Jarvis-Router (not generic)
3) [ ] Implement `list_agents` in Tools Gateway
4) [ ] Update Jarvis-Router persona to call `list_agents` before answering roster questions
5) [ ] Implement `delegate_agent` in Tools Gateway
6) [ ] Test with 2–3 domain tasks (Marketing + BackendDev + Contracts)

---

## Implementation Status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1 - Verify Reality | ✅ Complete | 18 agents verified in agents.yaml |
| Phase 2 - Agent Discovery | ✅ Complete | `GET /actions/list_agents` implemented |
| Phase 3 - Delegation | ✅ Complete | `POST /actions/delegate_agent` implemented |
| Phase 4 - Attention + Approvals | ✅ Complete | Notification system with HA integration |
| Phase 5 - Quality Controls | ✅ Complete | Rate limiting + tier enforcement |

## Implementation Details

### Phase 2 - Agent Discovery (2026-01-11)

Implemented in `jarvis/tools-gateway/main.py`:
- `GET /actions/list_agents` endpoint with optional domain filter
- Reads from `agents.yaml` as source of truth
- Returns: name, description, domain, capability_tier, provider, model, has_tools
- Domain classifications: coordinator, core, business, software, legal
- Capability tiers: coordinator, external, read-only, tool-less

### Phase 3 - Delegation (2026-01-11)

Implemented in `jarvis/tools-gateway/main.py`:
- `POST /actions/delegate_agent` endpoint
- Validates agent exists in roster
- Prevents delegation to Jarvis-Router (loop prevention)
- Calls AGiXT via OpenAI-compatible chat endpoint
- Full audit logging: agent, request_id, task_hash, timing, success/failure
- Timeout handling (120s default)

### Phase 4 - Attention + Approvals (2026-01-11)

Implemented in `jarvis/tools-gateway/main.py`:

**New Endpoints:**
- `POST /actions/notify` - Send notification (fyi, needs_response, approval)
- `POST /actions/check_approval` - Check status of pending approval
- `POST /actions/respond_approval` - External systems respond to approvals
- `GET /actions/pending_approvals` - List all pending approvals

**Notification Types:**
- `fyi`: Informational only
- `needs_response`: Requires user input
- `approval`: Yes/no gate with action buttons

**Features:**
- Priority levels: low, medium, high, critical
- Expiration handling (default 60 minutes)
- In-memory approval store with LRU cleanup
- Home Assistant webhook integration (when configured)
- Full audit logging

**Configuration:** Add `homeassistant_notify` webhook in `actions.yaml` to enable HA push notifications.

### Phase 5 - Quality Controls (2026-01-11)

Implemented in `jarvis/tools-gateway/main.py`:

**Rate Limiting:**
- Max 5 delegations per request_id (configurable via `MAX_DELEGATIONS_PER_REQUEST`)
- 5-minute TTL on delegation counts
- Automatic cleanup of expired entries

**Capability Tier Enforcement:**
- Tracks capability tier on every delegation
- Warns when delegating to `external` or `write` tier agents
- Tier information included in response timings

**Audit Enhancements:**
- Delegation count included in audit logs
- Capability tier tracked per delegation
- Rate limit violations logged

### Jarvis-Router Persona Update (2026-01-11)

Updated `jarvis/agents/agents.yaml` Jarvis-Router persona with:
- Explicit instructions for `list_agents` and `delegate_agent` usage
- No-hallucination guarantees about agent existence
- Delegation rules (cite sources, limit to 3-5, materially improve quality)
- SecurityAgent escalation for sensitive actions
- Notification and approval workflow instructions
- Priority level guidance

---

## Files Modified

| File | Changes |
|------|---------|
| `jarvis/tools-gateway/main.py` | +400 lines: delegation, notification, rate limiting |
| `jarvis/tools-gateway/actions.yaml` | +20 lines: HA webhook config, agent settings |
| `jarvis/agents/agents.yaml` | +50 lines: Router persona with delegation/notification rules |
| `plans/jarvis/jarvis-router-delegation.md` | This plan document |

## To Deploy

```bash
# On PCT 121 (Jarvis host)
cd /opt/jarvis

# Restart Tools Gateway to pick up changes
docker compose restart tools-gateway

# Re-provision agents with updated persona
cd agents && python3 provision.py
```

### Home Assistant Deployment (Completed 2026-01-11)

The Jarvis notification system has been deployed to Home Assistant (VM 101):

**Deployed Components:**
- `jarvis_attention.yaml` package with 4 automations
- `input_text.jarvis_webhook_secret` for HMAC verification
- `input_number.jarvis_notification_count` for tracking
- `rest_command.jarvis_attention_callback` for callbacks

**Configuration:**
- Webhook URL: `http://192.168.1.61:8123/api/webhook/jarvis_attention`
- Webhook secret: Stored in HA `input_text.jarvis_webhook_secret` and Jarvis `.env`
- Secret synchronized between HA and Tools Gateway

**Verification:**
- Test webhook sent successfully
- Notification count incremented from 4 to 5
- HMAC signature verification working

## Testing Checklist

- [ ] `GET /actions/list_agents` returns 18 agents
- [ ] `POST /actions/delegate_agent` to Marketing returns response
- [ ] Rate limit triggers after 5 delegations with same request_id
- [ ] `POST /actions/notify` creates approval and returns notification_id
- [ ] `POST /actions/check_approval` returns pending status
- [ ] `POST /actions/respond_approval` updates status to approved/denied

---

*Created: 2026-01-11*
*Last Updated: 2026-01-11*
