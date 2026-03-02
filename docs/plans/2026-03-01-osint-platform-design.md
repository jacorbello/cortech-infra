# OSINT Platform — Engineering Design Document

**Date:** 2026-03-01
**Author:** Alastar (jacorbello)
**Status:** Approved
**PRD:** OSINT_PRD.md

---

## 1. Summary

Self-hosted OSINT monitoring platform deployed on the Cortech homelab (K3s on Proxmox). MVP focuses on **Use Case C: continuous threat intelligence monitoring** — feed ingestion, entity extraction, semantic correlation, scoring, alerting, and LLM-powered intel briefs, all driven by a declarative Collection Plan as Code.

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Core approach | Custom FastAPI monolith | Plan-as-code workflow doesn't map to existing platforms (DFIR-IRIS/TheHive). Lighter infra footprint. |
| MVP scope | Use Case C (monitoring + alerts) | Exercises full core pipeline. Immediate value from feed → score → alert → brief. |
| Code location | Separate repo (`osint-core`) | Follows existing pattern (Jarvis, PlotLens have own repos). cortech-infra holds IaC only. |
| Plan storage | In osint-core repo (`plans/`) | Git-native versioning, PRs for plan changes, CI validates schema. |
| Orchestration | osint-core owns scheduling (Celery Beat) | No n8n dependency. Single system for scheduling + job dispatch. |
| UI | API-only for MVP | FastAPI auto-generated OpenAPI/Swagger docs. Grafana for observability. UI is Phase 2. |
| Worker framework | Celery + Redis | Battle-tested. Beat for scheduling. Supports K8s Job dispatch for heavy work. |
| MCP server | Phase 2 | REST API with OpenAPI spec covers MVP. MCP wraps API for AI assistant integration later. |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  osint-core (FastAPI)         │  osint-worker (Celery)       │
│  ┌─────────────────────────┐  │  ┌─────────────────────────┐ │
│  │ Plan Engine             │  │  │ Feed Connectors         │ │
│  │ REST API (OpenAPI)      │  │  │  - NVD / CISA KEV / OSV │ │
│  │ Scoring Engine          │  │  │  - URLhaus / ThreatFox  │ │
│  │ Alert Router            │  │  │ Enrichment Pipeline     │ │
│  │ Brief Generator         │  │  │  - Entity extraction    │ │
│  │ Scheduler (Celery Beat) │  │  │  - Indicator normalize  │ │
│  └──────────┬──────────────┘  │  │  - Qdrant vectorize     │ │
│             │                 │  │ Correlation Engine       │ │
│             │                 │  │ Notification Dispatch    │ │
│             │                 │  └──────────┬──────────────┘ │
└─────────────┼─────────────────┴─────────────┼───────────────┘
              │                               │
    ┌─────────▼───────────────────────────────▼──────┐
    │              Shared Dependencies                │
    │  Postgres (LXC 114)  │  Redis (LXC 116)        │
    │  MinIO (LXC 123)     │  Qdrant (K8s, osint ns)  │
    │  Ollama (VM 205)     │  Gotify (K8s, osint ns)   │
    └─────────────────────────────────────────────────┘

    Batch Jobs (wrk-3 only):
    ┌──────────┐  ┌────────┐
    │  spaCy   │  │  Tika  │   (dispatched by Celery as K8s Jobs)
    │  NER     │  │ parser │
    └──────────┘  └────────┘
```

### Component Responsibilities

**osint-core (FastAPI):**
- Plan engine: load, validate, version, activate, rollback YAML plans
- REST API: all endpoints (events, alerts, briefs, search, indicators, entities, jobs, audit)
- Scoring engine: apply plan-defined weights, recency decay, IOC boosts
- Brief generator: Ollama-powered with Jinja2 template fallback
- Keycloak OIDC token validation and role mapping

**osint-worker (Celery):**
- Feed connectors: poll sources on Celery Beat schedule
- Enrichment: indicator normalization, entity extraction dispatch
- Vectorization: sentence-transformers embeddings → Qdrant upsert
- Correlation: exact match + semantic similarity (Qdrant)
- K8s Job dispatch: create batch Jobs on wrk-3 for NER/Tika
- Notification dispatch: Apprise multi-channel delivery

**osint-beat (Celery Beat):**
- Scheduler: rebuild schedules from active plan's source definitions
- Triggers: feed polling, watchlist re-checks, digest compilation

### Key Architectural Choices

- **Single Python package** for FastAPI + Celery (shared models, schemas, config)
- **Same Docker image** for core, worker, and beat (different entrypoints)
- **K8s Jobs** for heavy processing (NER, Tika) on wrk-3 — dispatched by Celery, polled for completion
- **ExternalName Services** for all LXC dependencies (Postgres, Redis, MinIO, Ollama)
- **No n8n dependency** — osint-core owns all scheduling and orchestration

---

## 3. Tech Stack

### Application (osint-core repo)

| Layer | Choice | Version |
|-------|--------|---------|
| Web framework | FastAPI | 0.115+ |
| Task queue | Celery (Redis broker) | 5.4+ |
| Scheduler | Celery Beat | (bundled) |
| ORM | SQLAlchemy 2.0 (async) | 2.0+ |
| Migrations | Alembic | 1.13+ |
| HTTP client | httpx (async) | 0.27+ |
| Schema validation | Pydantic v2 + jsonschema | — |
| YAML parsing | PyYAML + strictyaml | — |
| NER | spaCy (`en_core_web_sm` + EntityRuler) | 3.x |
| Embeddings | sentence-transformers (`all-MiniLM-L6-v2`) | — |
| Vector DB client | qdrant-client | — |
| Notifications | apprise | — |
| Metrics | prometheus-fastapi-instrumentator | — |
| Logging | structlog | — |
| Linting | ruff + mypy | — |
| Testing | pytest + pytest-asyncio + factory-boy | — |
| Container | Docker multi-stage → Harbor | — |

### Infrastructure (cortech-infra repo)

| Component | Format | Location |
|-----------|--------|----------|
| K8s manifests | Kustomize (base + production overlay) | `apps/osint/` |
| NGINX proxy | Server block config | `proxy/sites/osint.corbello.io.conf` |
| ArgoCD | Application manifest | `apps/osint/argocd-application.yaml` |
| Grafana dashboard | ConfigMap (sidecar pattern) | `k8s/observability/dashboards/applications/osint-platform.yaml` |
| ExternalName services | K8s Service YAML | `apps/osint/base/external-services/` |

---

## 4. Data Model (Postgres Schema)

All tables in a dedicated `osint` schema on Postgres LXC 114. Managed by Alembic migrations.

### Core Tables

```sql
-- Plan versioning
CREATE TABLE osint.plan_versions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id         TEXT NOT NULL,
    version         INTEGER NOT NULL,
    content_hash    TEXT NOT NULL,
    content         JSONB NOT NULL,
    retention_class TEXT NOT NULL CHECK (retention_class IN ('ephemeral','standard','evidentiary')),
    git_commit_sha  TEXT,
    activated_at    TIMESTAMPTZ,
    activated_by    TEXT,
    is_active       BOOLEAN DEFAULT FALSE,
    validation_result JSONB,
    created_at      TIMESTAMPTZ DEFAULT now(),
    UNIQUE(plan_id, version)
);

-- Events (time-bound observations)
CREATE TABLE osint.events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    title           TEXT,
    summary         TEXT,
    raw_excerpt     TEXT,
    occurred_at     TIMESTAMPTZ,
    ingested_at     TIMESTAMPTZ DEFAULT now(),
    score           FLOAT,
    severity        TEXT CHECK (severity IN ('info','low','medium','high','critical')),
    dedupe_fingerprint TEXT NOT NULL,
    plan_version_id UUID REFERENCES osint.plan_versions(id),
    metadata        JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_events_dedupe ON osint.events(dedupe_fingerprint);
CREATE INDEX idx_events_source ON osint.events(source_id, ingested_at DESC);
CREATE INDEX idx_events_score ON osint.events(score DESC NULLS LAST);

-- Postgres FTS (generated column)
ALTER TABLE osint.events ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(title,'') || ' ' || coalesce(summary,'') || ' ' || coalesce(raw_excerpt,''))
    ) STORED;
CREATE INDEX idx_events_fts ON osint.events USING GIN(search_vector);

-- Entities (people, orgs, products, etc.)
CREATE TABLE osint.entities (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type     TEXT NOT NULL,
    name            TEXT NOT NULL,
    aliases         TEXT[] DEFAULT '{}',
    attributes      JSONB DEFAULT '{}',
    first_seen      TIMESTAMPTZ DEFAULT now(),
    last_seen       TIMESTAMPTZ DEFAULT now(),
    created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_entities_name ON osint.entities USING GIN(to_tsvector('english', name));

-- Indicators (observables / IOCs)
CREATE TABLE osint.indicators (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    indicator_type  TEXT NOT NULL,
    value           TEXT NOT NULL,
    confidence      FLOAT DEFAULT 0.5,
    first_seen      TIMESTAMPTZ DEFAULT now(),
    last_seen       TIMESTAMPTZ DEFAULT now(),
    sources         TEXT[] DEFAULT '{}',
    metadata        JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT now(),
    UNIQUE(indicator_type, value)
);

-- Artifacts (for Phase 2 evidence capture — schema defined now)
CREATE TABLE osint.artifacts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_type   TEXT NOT NULL,
    minio_uri       TEXT,
    minio_version_id TEXT,
    sha256          TEXT,
    capture_tool    TEXT,
    source_url      TEXT,
    final_url       TEXT,
    http_status     INTEGER,
    retention_class TEXT DEFAULT 'standard',
    plan_version_id UUID REFERENCES osint.plan_versions(id),
    case_id         UUID,
    created_at      TIMESTAMPTZ DEFAULT now()
);

-- Junction tables
CREATE TABLE osint.event_entities (
    event_id UUID REFERENCES osint.events(id) ON DELETE CASCADE,
    entity_id UUID REFERENCES osint.entities(id) ON DELETE CASCADE,
    PRIMARY KEY (event_id, entity_id)
);

CREATE TABLE osint.event_indicators (
    event_id UUID REFERENCES osint.events(id) ON DELETE CASCADE,
    indicator_id UUID REFERENCES osint.indicators(id) ON DELETE CASCADE,
    PRIMARY KEY (event_id, indicator_id)
);

CREATE TABLE osint.event_artifacts (
    event_id UUID REFERENCES osint.events(id) ON DELETE CASCADE,
    artifact_id UUID REFERENCES osint.artifacts(id) ON DELETE CASCADE,
    PRIMARY KEY (event_id, artifact_id)
);

-- Alerts
CREATE TABLE osint.alerts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint     TEXT NOT NULL,
    severity        TEXT NOT NULL,
    title           TEXT NOT NULL,
    summary         TEXT,
    event_ids       UUID[] DEFAULT '{}',
    indicator_ids   UUID[] DEFAULT '{}',
    entity_ids      UUID[] DEFAULT '{}',
    route_name      TEXT,
    status          TEXT DEFAULT 'open' CHECK (status IN ('open','acked','escalated','resolved')),
    occurrences     INTEGER DEFAULT 1,
    first_fired_at  TIMESTAMPTZ DEFAULT now(),
    last_fired_at   TIMESTAMPTZ DEFAULT now(),
    acked_at        TIMESTAMPTZ,
    acked_by        TEXT,
    plan_version_id UUID REFERENCES osint.plan_versions(id),
    created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_alerts_fingerprint ON osint.alerts(fingerprint, last_fired_at DESC);

-- Briefs
CREATE TABLE osint.briefs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title           TEXT NOT NULL,
    content_md      TEXT NOT NULL,
    content_pdf_uri TEXT,
    target_query    TEXT,
    event_ids       UUID[] DEFAULT '{}',
    entity_ids      UUID[] DEFAULT '{}',
    indicator_ids   UUID[] DEFAULT '{}',
    generated_by    TEXT DEFAULT 'ollama',
    model_id        TEXT,
    plan_version_id UUID REFERENCES osint.plan_versions(id),
    requested_by    TEXT,
    created_at      TIMESTAMPTZ DEFAULT now()
);

-- Audit log (append-only)
CREATE TABLE osint.audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action          TEXT NOT NULL,
    actor           TEXT,
    actor_username  TEXT,
    actor_roles     TEXT[],
    resource_type   TEXT,
    resource_id     TEXT,
    details         JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_audit_log_time ON osint.audit_log(created_at DESC);

-- Jobs tracking
CREATE TABLE osint.jobs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type        TEXT NOT NULL,
    status          TEXT DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','dead_letter')),
    celery_task_id  TEXT,
    k8s_job_name    TEXT,
    input_params    JSONB DEFAULT '{}',
    output          JSONB DEFAULT '{}',
    error           TEXT,
    retry_count     INTEGER DEFAULT 0,
    next_retry_at   TIMESTAMPTZ,
    idempotency_key TEXT,
    plan_version_id UUID REFERENCES osint.plan_versions(id),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE UNIQUE INDEX idx_jobs_idempotency ON osint.jobs(idempotency_key) WHERE idempotency_key IS NOT NULL;
```

### Design Notes

- **Generated FTS column** on events for keyword search without separate indexing
- **Dedupe fingerprint** on events prevents duplicate ingestion
- **Idempotency keys** on jobs prevents duplicate processing
- **Artifacts table defined now** (evidence capture is Phase 2) for schema stability
- **Array columns** on alerts for event/indicator/entity references (simpler than junction tables for read-heavy alert queries)
- **Append-only audit log** with Keycloak identity fields

---

## 5. Collection Plan Engine

### Plan Lifecycle

```
plans/libertycenter.yaml
  → YAML parse (PyYAML)
  → JSON Schema validate (jsonschema)
  → safety check (regex for embedded secrets)
  → content hash (SHA-256)
  → compare against latest stored version
  → if changed: store in plan_versions
  → activate: set is_active=true, deactivate previous
  → reconfigure Celery Beat schedules from sources
  → emit audit log entry
```

### Hot-Reload

On startup and via `POST /plan/sync`, osint-core:
1. Reads `plans/*.yaml` from disk (mounted from repo or synced via git)
2. Hashes each file's content
3. Compares against latest stored version in `plan_versions`
4. If content changed: validates, stores new version, optionally auto-activates

Celery Beat schedules are rebuilt from the active plan's `sources` definitions. Each source becomes a periodic task with the interval defined in the plan (or connector defaults).

### Validation

- **YAML lint:** structural correctness
- **JSON Schema:** semantic validation (required fields, enum values, type checks)
- **Connector validation:** every `source.type` must have a registered connector class
- **Safety validation:** regex scan for API keys, passwords, tokens — reject if found
- **Dry-run mode:** `POST /plan/validate` returns diagnostics + "diff of behavior" (what sources/alerts would change)

### Rollback

`POST /plan/rollback` sets `is_active=true` on the previous accepted plan version. Celery Beat schedules are rebuilt. Audit log records the rollback with actor identity.

---

## 6. Feed Pipeline

### Connector Architecture

```python
class BaseConnector(ABC):
    source_config: SourceConfig  # from plan YAML

    @abstractmethod
    async def fetch(self) -> list[RawItem]:
        """Fetch new items from the source."""

    def dedupe_key(self, item: RawItem) -> str:
        """Generate idempotency fingerprint for deduplication."""
```

### MVP Connectors

| Connector | Source type | Default interval | Notes |
|-----------|-----------|-----------------|-------|
| `CISAKEVConnector` | `cisa_kev` | 6 hours | JSON catalog, diff against last known state |
| `NVDConnector` | `nvd_json_feed` | 4 hours | NVD API 2.0, paginated, 5 req/30s rate limit |
| `OSVConnector` | `osv_api` | 6 hours | Batch query API by ecosystem/package |
| `URLhausConnector` | `urlhaus_api` | 2 hours | Recent URLs feed (CSV/JSON) |
| `ThreatFoxConnector` | `threatfox_api` | 4 hours | IOC feed JSON API |
| `RSSConnector` | `rss` | Plan-defined | Generic RSS/Atom parser |

### Pipeline Flow

```
Celery Beat trigger → ingest_source_task(source_id)
  → connector = ConnectorRegistry.get(source.type)
  → items = await connector.fetch()
  → for each item:
      1. fingerprint = connector.dedupe_key(item)
      2. if event_exists(fingerprint, within=dedupe_window): skip
      3. event = create_event(item)
      4. indicators = extract_indicators(item)  # URL, domain, IP, hash, CVE
      5. link indicators to event
      6. dispatch enrichment chain:
         a. enrich_entities_task(event_id)   → spaCy NER (K8s Job on wrk-3 if text available)
         b. vectorize_event_task(event_id)   → sentence-transformers → Qdrant upsert
         c. correlate_event_task(event_id)   → exact match + Qdrant similarity
      7. score_event_task(event_id)          → apply plan weights
      8. if score > threshold → create_alert_task(event_id) → route notification
```

### Enrichment on wrk-3

For items requiring NER or Tika processing, Celery dispatches K8s Jobs:

```python
async def dispatch_k8s_job(job_type: str, params: dict) -> str:
    job_manifest = build_job_manifest(
        name=f"osint-{job_type}-{uuid4().hex[:8]}",
        image=f"harbor.corbello.io/osint/{job_type}:latest",
        args=params,
        node_selector={"role": "batch-compute"},
        tolerations=[{
            "key": "node.kubernetes.io/lifecycle",
            "value": "ephemeral",
            "effect": "NoSchedule"
        }],
        resources=RESOURCE_LIMITS[job_type],
    )
    # Create job via kubernetes client, poll for completion
```

### wrk-3 Unavailability

When wrk-3 (cortech-node3) is offline:
- NER jobs queue with retry + exponential backoff
- Events are still created and scored (without entity enrichment)
- Alert on wrk-3 unavailability to operator
- Lightweight indicator extraction (regex-based) runs in-process as fallback

---

## 7. Scoring Engine

```python
def score_event(event: Event, plan: ActivePlan) -> float:
    base_score = 0.0

    # Source reputation weight
    base_score += plan.scoring.source_reputation.get(event.source_id, 1.0)

    # Recency decay (half-life model)
    hours_old = (now() - event.occurred_at).total_seconds() / 3600
    recency_factor = 0.5 ** (hours_old / plan.scoring.recency_half_life_hours)
    base_score *= recency_factor

    # IOC match boost
    if event.indicator_ids:
        base_score *= plan.scoring.ioc_match_boost

    # Focus topic multipliers
    for topic in plan.focus.topics:
        if matches_topic(event, topic):
            base_score *= topic.priority_multiplier

    # Force-alert override
    if meets_force_alert(event, plan.scoring.force_alert):
        event.severity = max(event.severity, plan.scoring.force_alert.min_severity)

    return base_score
```

### Topic Matching

`matches_topic()` checks event title/summary/indicators against topic keywords and regions. Uses both exact keyword matching and optional semantic similarity (Qdrant query with topic keyword embeddings as reference vectors).

---

## 8. Notification System

### Alert Flow

```
Event scored → exceeds threshold?
  → compute fingerprint = hash(plan_id + normalized_indicators + canonical_url)
  → check dedupe window (plan-configurable per route, default 90 min)
  → if existing alert within window: increment occurrences, skip notify
  → if new: match against plan notification routes
  → check quiet hours (plan.notifications.quiet_hours)
  → if quiet + not force_alert: queue for digest
  → else: dispatch via Apprise to matched channels
```

### Channels (MVP)

| Channel | Transport | Notes |
|---------|-----------|-------|
| Gotify | REST API (K8s, osint namespace) | Self-hosted push notifications + web UI |
| Discord | Webhook via Apprise | Webhook URL in K8s Secret |
| Email | SMTP via Apprise | SMTP config in K8s Secret |

### Escalation

Escalate if:
1. Same fingerprint fires again with higher severity
2. 3+ independent sources corroborate within 2 hours
3. Watchlist item changed in a high-impact way (Phase 2)

Escalation routes can promote from Gotify → email based on plan configuration.

### Quiet Hours

- Suppress low/medium alerts during configured quiet hours
- Accumulate into digest (compiled and sent when quiet hours end)
- `force_alert` overrides bypass quiet hours

---

## 9. Intel Brief Generation

### Flow

```
POST /briefs/generate { "query": "Brief me on CVE-2026-XXXX" }
  → resolve query:
      keyword search (Postgres FTS) + semantic search (Qdrant)
  → gather top-N Events by score + recency
  → deduplicate by story cluster (Qdrant similarity > 0.85)
  → build context payload (events, indicators, entities)
  → primary: Ollama (VM 205, llama3.1:8b)
      system: "You are an intelligence analyst..."
      user: structured prompt with context
  → fallback: Jinja2 template (if Ollama unavailable)
  → store Brief in Postgres
  → return Brief object
```

### Template Fallback

The platform MUST work without Ollama (wrk-3/node3 can be offline). The Jinja2 template produces structured markdown from the same data:

```markdown
# Intel Brief: {{ title }}
**Generated:** {{ timestamp }} | **Confidence:** {{ confidence }}

## Executive Summary
{{ summary_from_top_events }}

## Key Events
{% for event in events %}
- **{{ event.title }}** ({{ event.severity }}, score: {{ event.score }})
  Source: {{ event.source_id }} | {{ event.occurred_at }}
{% endfor %}

## Indicators
{% for indicator in indicators %}
- {{ indicator.type }}: `{{ indicator.value }}`
{% endfor %}

## Evidence Links
{% for event in events %}
- [{{ event.title }}]({{ event.source_url }})
{% endfor %}
```

---

## 10. API Design

Base URL: `https://osint.corbello.io/api/v1`

All endpoints require Keycloak JWT (except health checks). FastAPI dependency injection handles token validation and role extraction.

### Endpoints

```
Health:
  GET  /healthz                              → 200 OK
  GET  /readyz                               → 200 OK (checks DB + Redis + Qdrant)

Plan:
  GET  /plan/active                          → current active plan
  GET  /plan/versions                        → list all plan versions
  POST /plan/sync                            → trigger plan reload from disk/git
  POST /plan/validate                        → upload candidate plan, returns diagnostics
  POST /plan/rollback                        → revert to previous plan version
  POST /plan/activate/{version_id}           → activate a specific version

Ingestion:
  POST /ingest/source/{source_id}/run        → trigger immediate source ingestion
  GET  /ingest/sources                       → list configured sources + last run status
  GET  /ingest/history                       → recent ingestion runs

Events:
  GET  /events                               → paginated (filters: source, severity, date range)
  GET  /events/{event_id}                    → detail with linked entities/indicators

Search:
  GET  /search                               → keyword search (Postgres FTS)
  GET  /search/semantic                      → semantic search (Qdrant)

Indicators:
  GET  /indicators                           → paginated indicator list
  GET  /indicators/{indicator_id}            → detail with linked events
  GET  /indicators/lookup?type=&value=       → quick lookup

Entities:
  GET  /entities                             → paginated entity list
  GET  /entities/{entity_id}                 → detail with linked events

Alerts:
  GET  /alerts                               → paginated (filters: status, severity, date)
  GET  /alerts/{alert_id}                    → alert detail
  POST /alerts/{alert_id}/ack               → acknowledge
  POST /alerts/{alert_id}/escalate          → manually escalate
  POST /alerts/{alert_id}/resolve           → resolve

Briefs:
  POST /briefs/generate                      → generate intel brief
  GET  /briefs                               → list briefs
  GET  /briefs/{brief_id}                    → brief detail

Jobs:
  GET  /jobs                                 → run history (filters: type, status)
  GET  /jobs/{job_id}                        → job detail
  POST /jobs/{job_id}/retry                  → retry a failed job

Audit:
  GET  /audit                                → audit log (filters: action, actor, date)
```

### Auth Model

Keycloak groups → roles:

| Role | Permissions |
|------|-------------|
| `osint-operator` | Full access: plan management, job control, admin |
| `osint-analyst` | Read events/alerts/briefs, ack alerts, generate briefs, search |
| `osint-readonly` | Read-only access to events, alerts, briefs |

---

## 11. Infrastructure & Deployment

### K8s Deployments (osint namespace)

| Deployment | Replicas | CPU req/lim | Mem req/lim | Node affinity | Image |
|-----------|----------|-------------|-------------|---------------|-------|
| osint-core | 1 | 250m/1000m | 256Mi/512Mi | wrk-1/wrk-2 | `harbor.corbello.io/osint/osint-core:<sha>` |
| osint-worker | 1 | 250m/500m | 256Mi/512Mi | wrk-1/wrk-2 | `harbor.corbello.io/osint/osint-core:<sha>` |
| osint-beat | 1 | 100m/250m | 128Mi/256Mi | wrk-1/wrk-2 | `harbor.corbello.io/osint/osint-core:<sha>` |
| qdrant | 1 | 250m/1000m | 512Mi/1Gi | wrk-1/wrk-2 | `harbor.corbello.io/dockerhub-cache/qdrant/qdrant:latest` |
| gotify | 1 | 50m/200m | 64Mi/128Mi | wrk-1/wrk-2 | `harbor.corbello.io/dockerhub-cache/gotify/server:latest` |

**Steady-state footprint:** ~900m CPU requests, ~1.2 GiB memory requests on wrk-1/wrk-2.

### Batch Job Templates (wrk-3 only)

| Job | CPU req/lim | Mem req/lim | Image |
|-----|-------------|-------------|-------|
| spacy-ner | 500m/1000m | 512Mi/1Gi | `harbor.corbello.io/osint/spacy-ner:latest` |
| tika | 500m/1000m | 1Gi/2Gi | `harbor.corbello.io/dockerhub-cache/apache/tika:latest` |

All batch jobs require:
- `nodeSelector: { role: batch-compute }`
- `tolerations: [{ key: node.kubernetes.io/lifecycle, value: ephemeral, effect: NoSchedule }]`

### ExternalName Services

```yaml
postgres.osint.svc.cluster.local  → 192.168.1.52:5432
redis.osint.svc.cluster.local     → 192.168.1.52:6379
minio.osint.svc.cluster.local     → 192.168.1.52:9000
ollama.osint.svc.cluster.local    → 192.168.1.114:11434
```

### Resource Guardrails

**ResourceQuota (osint namespace):**
- 8 CPU requests / 16 CPU limits
- 16Gi memory requests / 32Gi memory limits
- Max 20 pods, max 6 batch jobs

**LimitRange defaults:**
- Default: 500m CPU, 512Mi memory
- Default request: 100m CPU, 128Mi memory
- Max: 4 CPU, 8Gi memory

**PriorityClasses:**
- `osint-core` (100): core services
- `osint-batch` (10): batch jobs (preemptible)

### NGINX Proxy

```nginx
# proxy/sites/osint.corbello.io.conf
server {
    listen 443 ssl http2;
    server_name osint.corbello.io;

    ssl_certificate     /etc/letsencrypt/live/osint.corbello.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/osint.corbello.io/privkey.pem;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://192.168.1.90;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    access_log /var/log/nginx/osint.corbello.io.access.log;
    error_log  /var/log/nginx/osint.corbello.io.error.log;
}

server {
    listen 80;
    server_name osint.corbello.io;
    return 301 https://$host$request_uri;
}
```

### ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: osint-platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jacorbello/cortech-infra.git
    targetRevision: main
    path: apps/osint/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: osint
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### CI/CD (GitHub Actions → ARC)

In the osint-core repo:
1. **PR:** lint (ruff, mypy) + test (pytest) + schema validate
2. **Merge to main:** Docker multi-stage build → push to `harbor.corbello.io/osint/osint-core:<sha>`
3. **Deploy:** Update image tag in `apps/osint/overlays/production/kustomization.yaml` (cortech-infra repo)
4. **Sync:** ArgoCD detects change → syncs to cluster

### Observability

**Grafana dashboard** (ConfigMap with `grafana_dashboard: "1"` label):
- Panels: ingestion success/failure rates, events per source, alert volume, scoring distribution, job status, Qdrant stats, Celery queue depth

**ServiceMonitor** for Prometheus scraping osint-core `/metrics` endpoint.

**Structured JSON logs** with correlation IDs (job_id, event_id) → collected by Promtail → Loki.

---

## 12. Repo Layout

### osint-core repo (new, separate)

```
osint-core/
├── src/
│   └── osint_core/
│       ├── __init__.py
│       ├── main.py                     # FastAPI app entrypoint
│       ├── config.py                   # Settings (Pydantic BaseSettings)
│       ├── api/
│       │   ├── __init__.py
│       │   ├── deps.py                 # Dependency injection (DB, auth, etc.)
│       │   ├── routes/
│       │   │   ├── health.py
│       │   │   ├── plan.py
│       │   │   ├── ingest.py
│       │   │   ├── events.py
│       │   │   ├── search.py
│       │   │   ├── indicators.py
│       │   │   ├── entities.py
│       │   │   ├── alerts.py
│       │   │   ├── briefs.py
│       │   │   ├── jobs.py
│       │   │   └── audit.py
│       │   └── middleware/
│       │       └── auth.py             # Keycloak OIDC validation
│       ├── models/                     # SQLAlchemy models
│       │   ├── event.py
│       │   ├── entity.py
│       │   ├── indicator.py
│       │   ├── artifact.py
│       │   ├── alert.py
│       │   ├── brief.py
│       │   ├── plan.py
│       │   ├── job.py
│       │   └── audit.py
│       ├── schemas/                    # Pydantic request/response schemas
│       ├── services/                   # Business logic
│       │   ├── plan_engine.py
│       │   ├── scoring.py
│       │   ├── correlation.py
│       │   ├── notification.py
│       │   └── brief_generator.py
│       ├── connectors/                 # Feed connectors
│       │   ├── base.py
│       │   ├── registry.py
│       │   ├── cisa_kev.py
│       │   ├── nvd.py
│       │   ├── osv.py
│       │   ├── urlhaus.py
│       │   ├── threatfox.py
│       │   └── rss.py
│       ├── workers/                    # Celery tasks
│       │   ├── celery_app.py
│       │   ├── ingest.py
│       │   ├── enrich.py
│       │   ├── score.py
│       │   ├── notify.py
│       │   └── k8s_dispatch.py
│       └── templates/                  # Jinja2 brief templates
│           └── brief_default.md.j2
├── plans/                              # Collection Plan YAML files
│   └── example.yaml
├── schemas/                            # JSON Schema for plan validation
│   └── plan-v1.schema.json
├── migrations/                         # Alembic migrations
│   ├── alembic.ini
│   ├── env.py
│   └── versions/
├── tests/
├── Dockerfile
├── docker-compose.dev.yaml             # Local development
├── pyproject.toml
└── .github/
    └── workflows/
        └── ci.yaml
```

### cortech-infra repo additions

```
apps/
└── osint/
    ├── argocd-application.yaml
    ├── base/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── osint-core/
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   └── ingress.yaml
    │   ├── osint-worker/
    │   │   └── deployment.yaml
    │   ├── osint-beat/
    │   │   └── deployment.yaml
    │   ├── qdrant/
    │   │   ├── statefulset.yaml
    │   │   ├── service.yaml
    │   │   └── pvc.yaml
    │   ├── gotify/
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   └── pvc.yaml
    │   ├── jobs/
    │   │   ├── spacy-ner-job.yaml
    │   │   └── tika-job.yaml
    │   ├── external-services/
    │   │   ├── postgres.yaml
    │   │   ├── redis.yaml
    │   │   ├── minio.yaml
    │   │   └── ollama.yaml
    │   ├── rbac/
    │   │   ├── resource-quota.yaml
    │   │   ├── limit-range.yaml
    │   │   ├── priority-classes.yaml
    │   │   └── service-account.yaml
    │   ├── network-policies/
    │   │   └── default-deny.yaml
    │   └── monitoring/
    │       └── service-monitor.yaml
    └── overlays/
        └── production/
            └── kustomization.yaml

proxy/sites/
└── osint.corbello.io.conf

k8s/observability/dashboards/applications/
└── osint-platform.yaml
```

---

## 13. Phased Roadmap

### Phase 0: Foundations

- Postgres schema (Alembic migrations) on LXC 114
- Plan engine (YAML → validate → store → activate)
- osint-core skeleton (FastAPI + health/plan endpoints)
- Celery + Beat setup with Redis (LXC 116)
- K8s namespace + ResourceQuota + LimitRange + ExternalName services
- ArgoCD Application manifest
- NGINX proxy config
- Dockerfile + CI pipeline
- Gotify deployment

### Phase 1: Full Use Case C (MVP)

- All 6 feed connectors (CISA KEV, NVD, OSV, URLhaus, ThreatFox, RSS)
- Indicator extraction + normalization
- Entity extraction (spaCy NER via K8s Jobs on wrk-3)
- Qdrant vectorization + semantic correlation
- Scoring engine with plan-defined weights
- Alert creation + routing (Gotify + Discord + email via Apprise)
- Dedupe, quiet hours, escalation
- Intel brief generation (Ollama + template fallback)
- Full REST API
- Keycloak OIDC integration
- Prometheus metrics + Grafana dashboard
- Structured JSON logs → Loki

### Phase 2: Investigation + UX

- Evidence capture (Browsertrix + Playwright on wrk-3)
- Case management (create, tasks, evidence, bundles)
- MinIO bucket versioning + Object Lock for evidence
- MCP server wrapping REST API
- UI (admin dashboard or DFIR-IRIS integration)
- Watchlists + change detection
- Evidence signing

### Phase 3: CTI Knowledge Graph

- MISP integration (IOC sharing/sync)
- OpenCTI (STIX knowledge graph)
- Advanced correlation + graph exploration

---

## 14. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| wrk-3 offline | NER/Tika jobs fail | Queue with retry; regex-based fallback for indicators; alert operator |
| Ollama unavailable | No LLM briefs | Jinja2 template fallback; platform works without LLM |
| wrk-1/wrk-2 overcommitted | Pod evictions | ResourceQuota enforced; lean resource requests; pin heavy work to wrk-3 |
| Feed format changes | Ingestion breaks | Modular connectors; schema validation; monitor ingestion errors |
| Alert storm | Notification fatigue | Fingerprint dedup + time windows + semantic clustering |
| LXC ↔ K8s latency | Slow operations | ExternalName services; health checks; retry/backoff |
| Dev effort for custom monolith | Slow delivery | Phased approach; Phase 0 delivers plan engine first; iterate |

---

## 15. Definition of Done (MVP)

- [ ] Plan-as-code: YAML validated, hot-reload, versioned, rollback
- [ ] 6 feed connectors: NVD, CISA KEV, OSV, URLhaus, ThreatFox, RSS
- [ ] Event/Entity/Indicator model in Postgres with FTS
- [ ] Qdrant semantic search + correlation
- [ ] spaCy NER (K8s Jobs on wrk-3)
- [ ] Scoring engine (source weights, recency decay, IOC boost, force-alert)
- [ ] Alerts: Gotify + Apprise, dedupe, quiet hours, escalation
- [ ] Intel briefs: Ollama + template fallback
- [ ] REST API with OpenAPI docs
- [ ] Keycloak OIDC integration
- [ ] Prometheus metrics + Grafana dashboard
- [ ] Structured logs → Loki
- [ ] ResourceQuota + LimitRange enforced
- [ ] ArgoCD deployment from cortech-infra
- [ ] NGINX proxy config
- [ ] ExternalName services for LXC deps
- [ ] CI/CD: lint + test + build + push to Harbor
