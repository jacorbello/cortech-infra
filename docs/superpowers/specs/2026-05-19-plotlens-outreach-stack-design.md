# PlotLens Outreach Stack — Deployment Design

**Date:** 2026-05-19
**Status:** Approved (brainstorming complete)
**Author:** Jeremy Corbello

## Summary

Deploy a self-hosted, human-gated outreach pipeline for PlotLens that lets AI draft, score, summarize, and route — but never publish. The system is built in five phases on top of the existing Cortech homelab: existing n8n (LXC 112) and existing shared Postgres (LXC 114) plus new K3s workloads (Temporal, Postiz, listmonk) in a new `plotlens-marketing` namespace, all delivered via ArgoCD using the existing `apps/` pattern.

The core safety primitive is a Postgres trigger that rejects any publish attempt where the payload's SHA-256 hash does not match an unexpired, human-approved `approvals` row. n8n credential isolation is a layered (procedural) defense — the database enforces the hard guarantee.

## Goals

- Drive PlotLens outreach as "helpful editor who remembers canon," not "AI growth bot."
- Allow AI to discover, draft, score, and route — only humans approve, only approved-and-hashed payloads can publish.
- Reuse existing homelab infrastructure (n8n, shared Postgres, MinIO, observability) wherever possible.
- Plan cloud-portability for user-facing components (listmonk) from day one; keep admin tooling internal forever.
- Ship in five well-gated phases so each milestone is independently useful.

## Non-Goals

- No auto-reply on any platform. All replies are manual-paste in v1; Reddit replies remain manual indefinitely.
- No social-listening scraping. Discovery sources are limited to official APIs, RSS, Google Alerts, and manual URL paste.
- No marketing analytics warehouse. UTM-attributed signups land in listmonk; we read aggregate trends, not raw user content.
- No load testing or HA design for v1. Single-founder pipeline scale.
- No training on platform user content. Only aggregate learnings ("helpful-only replies converted better") feed back into prompts — never raw post text.
- Phase 4 visual channels (Instagram/Threads, TikTok, YouTube Shorts) are scoped only to setup + first scheduled post; ongoing visual content production is out of scope.

## Architecture

### Component placement

| Service | Placement | Domain | Repo path |
|---|---|---|---|
| Outreach DBs (`outreach`, `postiz`, `temporal`, `listmonk`) | Existing LXC 114 (shared Postgres) | n/a (internal only) | `apps/outreach-schema/` |
| n8n workflows | Existing LXC 112 (no deployment change) | `n8n.corbello.io` (existing) | `apps/outreach-workflows/n8n/` |
| Temporal (server + worker + UI) | K3s `plotlens-marketing` namespace, Helm via ArgoCD | `temporal.corbello.io` (UI, internal) | `apps/temporal/` |
| Postiz (web + worker) | K3s `plotlens-marketing` namespace via ArgoCD | `postiz.corbello.io`, `postiz-webhooks.corbello.io` (internal) | `apps/postiz/` |
| Postiz Redis | K3s `plotlens-marketing` namespace, dedicated StatefulSet | n/a | inside `apps/postiz/` |
| listmonk | K3s `plotlens-marketing` namespace via ArgoCD | `news.plotlens.ai` (user-facing) | `apps/listmonk/` |

### Internal vs user-facing split

Per the homelab convention ([memory: cortech-internal-vs-public-split]):

- **Internal (`*.corbello.io`, homelab forever):** n8n, Postiz admin UI, Postiz inbound webhooks, Temporal UI.
- **User-facing (`*.plotlens.ai`, homelab now → cloud-portable):** listmonk subscriber pages (subscribe, confirm, unsubscribe, archive). Outbound transactional email via AWS SES from day one — not homelab SMTP. Subscriber URL is stable across a future migration; cloud move is a DNS flip + `pg_dump` restore.

### Ingress & TLS

- All Kubernetes routes use Traefik `IngressRoute` (not plain `Ingress`) per the ArgoCD compatibility constraint ([memory: k3s-argocd-ingress-gotcha]).
- `corbello.io` already has a wildcard cert managed by cert-manager — no change.
- `plotlens.ai` requires a new `ClusterIssuer` with DNS-01 verification (whichever DNS provider runs `plotlens.ai`); added in Phase 3.

### Secrets

All new secrets in Infisical `dev` env per the homelab convention ([memory: cortech-infisical-env-convention]):

- `outreach-db` — connection string for the `outreach` DB
- `postiz` — Postiz admin password, Postiz API key, OAuth client secrets per platform
- `temporal` — Postgres connection, mTLS keys (if configured)
- `listmonk` — admin credentials, JWT secret
- `ses-smtp` — IAM access key for SES SMTP submission
- `openai`, `anthropic` — model provider keys
- `slack-bot` — Slack bot token + signing secret for the PlotLens workspace `#plotlens-outreach` channel

## Data Model

**Database:** `outreach` on LXC 114. Migrations as plain SQL via **dbmate**, committed to `apps/outreach-schema/db/migrations/`.

### Tables

```sql
CREATE TABLE outreach_items (
  id              BIGSERIAL PRIMARY KEY,
  source_platform TEXT NOT NULL CHECK (source_platform IN ('manual','rss','reddit','x','bluesky','mastodon','google_alerts')),
  source_url      TEXT NOT NULL,
  source_excerpt  TEXT,
  source_author   TEXT,
  source_community TEXT,
  topic           TEXT,
  persona         TEXT,
  intent_score    SMALLINT CHECK (intent_score BETWEEN 0 AND 100),
  risk_score      SMALLINT CHECK (risk_score BETWEEN 0 AND 100),
  status          TEXT NOT NULL DEFAULT 'discovered'
                    CHECK (status IN ('discovered','drafting','drafted','reviewed','rejected','archived')),
  discovered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_platform, source_url)
);
CREATE INDEX idx_outreach_items_status_discovered_at ON outreach_items (status, discovered_at);

CREATE TABLE drafts (
  id                BIGSERIAL PRIMARY KEY,
  outreach_item_id  BIGINT NOT NULL REFERENCES outreach_items(id),
  variant           TEXT NOT NULL CHECK (variant IN ('helpful_only','founder_context','soft_product')),
  model_provider    TEXT NOT NULL,
  model_name        TEXT NOT NULL,
  prompt_version    TEXT NOT NULL,
  draft_text        TEXT NOT NULL,
  suggested_destination TEXT NOT NULL,
  suggested_post_type   TEXT NOT NULL,
  claims_to_verify  JSONB NOT NULL DEFAULT '[]'::jsonb,
  risk_flags        JSONB NOT NULL DEFAULT '[]'::jsonb,
  risk_score        SMALLINT NOT NULL DEFAULT 50 CHECK (risk_score BETWEEN 0 AND 100),
  manual_only       BOOLEAN NOT NULL DEFAULT false,
  content_hash      TEXT NOT NULL,  -- sha256(draft_text || destination || post_type)
  status            TEXT NOT NULL DEFAULT 'needs_human_review'
                      CHECK (status IN ('needs_human_review','approved','rejected','expired')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_drafts_status_created_at ON drafts (status, created_at);

CREATE TABLE approvals (
  id                       BIGSERIAL PRIMARY KEY,
  draft_id                 BIGINT NOT NULL REFERENCES drafts(id),
  approved_by              TEXT NOT NULL,
  decision                 TEXT NOT NULL CHECK (decision IN ('approved','rejected','manual_only','save_for_later')),
  edited_text              TEXT,
  approved_destination     TEXT NOT NULL,
  approved_post_type       TEXT NOT NULL,
  approved_content_hash    TEXT NOT NULL,
  approval_notes           TEXT,
  approved_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at               TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '7 days'
);

CREATE TABLE publish_jobs (
  id                     BIGSERIAL PRIMARY KEY,
  approval_id            BIGINT NOT NULL REFERENCES approvals(id),
  destination_platform   TEXT NOT NULL,
  destination_account    TEXT NOT NULL,
  postiz_integration_id  TEXT,
  scheduled_for          TIMESTAMPTZ,
  publish_mode           TEXT NOT NULL CHECK (publish_mode IN ('postiz_scheduled','postiz_immediate','manual_required')),
  status                 TEXT NOT NULL DEFAULT 'ready'
                          CHECK (status IN ('ready','sent_to_postiz','scheduled','published','manual_post_required','failed','expired')),
  postiz_post_id         TEXT,
  published_url          TEXT,
  published_at           TIMESTAMPTZ,
  failure_reason         TEXT,
  payload_hash           TEXT NOT NULL
);
CREATE INDEX idx_publish_jobs_status_scheduled ON publish_jobs (status, scheduled_for);

CREATE TABLE outcomes (
  id              BIGSERIAL PRIMARY KEY,
  publish_job_id  BIGINT NOT NULL REFERENCES publish_jobs(id),
  impressions     INT,
  replies         INT,
  clicks          INT,
  signups         INT,
  notes           TEXT,
  captured_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Safety guarantee (DB trigger)

```sql
CREATE OR REPLACE FUNCTION enforce_approval_match() RETURNS trigger AS $$
DECLARE a approvals%ROWTYPE;
BEGIN
  SELECT * INTO a FROM approvals WHERE id = NEW.approval_id;
  IF a.decision <> 'approved' THEN
    RAISE EXCEPTION 'publish_job approval_id=% has decision=%, must be approved', NEW.approval_id, a.decision;
  END IF;
  IF a.expires_at < now() THEN
    RAISE EXCEPTION 'publish_job approval_id=% expired at %', NEW.approval_id, a.expires_at;
  END IF;
  IF NEW.payload_hash <> a.approved_content_hash THEN
    RAISE EXCEPTION 'publish_job payload_hash does not match approved_content_hash';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_enforce_approval_match
  BEFORE INSERT OR UPDATE OF payload_hash, approval_id ON publish_jobs
  FOR EACH ROW EXECUTE FUNCTION enforce_approval_match();
```

The trigger is the load-bearing safety mechanism. n8n credential isolation is layered defense; the trigger is the guarantee. Even a misbehaving workflow cannot bypass it.

## Workflow Design

Five n8n workflows on the single existing n8n instance. Each workflow's credentials are restricted to the matrix below. Discipline is procedural (n8n credentials are organization-scoped) but enforced by a CI audit script (see Testing) and backstopped by the DB trigger.

| Workflow | Holds | MUST NOT hold |
|---|---|---|
| A. Discover | RSS feed URLs, manual webhook secret | OpenAI, Anthropic, Postiz, SES |
| B. Draft | OpenAI, Anthropic, outreach DB | Postiz, SES, Slack publishing creds |
| C. Review | Outreach DB, Slack bot token (notify-only), n8n form auth | OpenAI, Anthropic, Postiz |
| D. Publish dispatcher | Outreach DB, Postiz API key | OpenAI, Anthropic (no LLM nodes period) |
| E. Outcome logger | Outreach DB, Postiz API key (analytics endpoints only — no create/publish nodes) | OpenAI, Anthropic, SES |

### A. Discover (v1 scope: manual webhook + RSS only)

- Trigger 1: webhook `POST /webhook/outreach-discover` with `{url, notes}` body, shared-secret authenticated.
- Trigger 2: schedule (every 30 min) → RSS Read for each feed in a config list.
- For each item: dedupe via `INSERT … ON CONFLICT (source_platform, source_url) DO NOTHING`; for v1, classification (topic/persona/intent) is keyword-match — LLM classification deferred to v2.
- Output: row in `outreach_items` with `status='discovered'`.

### B. Draft

- Trigger: schedule (every 5 min) → `SELECT … FROM outreach_items WHERE status='discovered' LIMIT 10`.
- For each row: set `status='drafting'` → call Anthropic Claude Sonnet 4.6 with structured prompt returning three variants (`helpful_only`, `founder_context`, `soft_product`) + per-variant `risk_flags` + `manual_only` flag → second-pass risk check via Claude Haiku 4.5 → insert three `drafts` rows with `content_hash` computed → set `outreach_items.status='drafted'`.
- Prompt versioned in repo at `apps/outreach-workflows/prompts/draft-v1.md`; `drafts.prompt_version` references the filename + git SHA.
- Prompt rubric (full text in the prompt file):
  - Voice: calm, practical, writer-friendly, no hype, no "AI slop".
  - Never claim PlotLens writes prose.
  - Never invent features, launch dates, metrics, integrations, prices, or customer counts.
  - Avoid developer jargon (entities, validation rules, embeddings). Use writer language (characters, story bible, continuity).
  - For Reddit: no sales CTA unless the post directly asks for tools.
  - For replies: answer the person's actual problem before mentioning anything we built.

### C. Review

- Trigger: schedule (every 2 min) → find `drafts WHERE status='needs_human_review'` that don't yet have a Slack notification logged.
- Slack message to `#plotlens-outreach`:

  ```
  📝 Draft ready (#1234) — Reddit /r/writing — risk 12/100
  Source: <url>
  Helpful-only preview: "First 200 chars…"
  → Review: https://n8n.corbello.io/form/approve-draft-1234
  [Approve as-drafted] [Reject] [Open full form]
  ```
- Slack quick-approve allowed only when no edits are needed and `drafts.risk_score < 20`; higher risk forces the form open.
- n8n hosted form: a single Form Trigger workflow at `https://n8n.corbello.io/form/approve-draft` that accepts `?draft_id=<id>` query parameter and loads draft + source context on render. Shows all three variants side-by-side, risk flags, edit textarea, destination dropdown, [Approve / Edit & Approve / Reject / Manual-Only / Save for Later] buttons.
- On submit: recompute `content_hash` from `edited_text` (or `draft_text` if no edit), insert `approvals` row, update `drafts.status`.
- Approval expiry: 7 days. A daily cron sets stale `drafts.status='expired'` and `approvals` rows past `expires_at` are unusable (rejected by the DB trigger if dispatcher tries them).

### D. Publish dispatcher (Phase 2, not v1)

- Trigger: schedule (every 2 min) → fetch `publish_jobs WHERE status='ready'`.
- For each: revalidate `payload_hash` against `approvals.approved_content_hash` before hitting the DB trigger (defense in depth).
  - `publish_mode IN ('postiz_scheduled','postiz_immediate')` → call Postiz API, store `postiz_post_id`, set `status='sent_to_postiz'`.
  - `publish_mode='manual_required'` → send Slack DM with approved text + source URL + "paste this manually" instructions, set `status='manual_post_required'`.

### E. Outcome logger (Phase 4)

- Trigger: schedule (hourly) → poll Postiz for `postiz_post_id` analytics, write `outcomes` rows.
- Pulls UTM-attributed signups from listmonk + analytics.
- Aggregate-only learnings feed back into prompt versioning. Never trains on raw user content.

## Phased Delivery

### Phase 0 — Temporal spike (1-2 days, throwaway)

Deploy Temporal via the `temporal-server` Helm chart to a sandbox namespace `temporal-spike` using raw `helm install` (not ArgoCD). Postgres backend (disable bundled Cassandra). Temporal UI reachable via port-forward only.

Run the official `temporal-sample-helloworld` workflow; restart the cluster; verify state survives and the worker reconnects.

Capture in `docs/runbooks/temporal-spike-findings.md`:
- Idle resource usage + usage under sample load
- Startup time
- K3s-specific gotchas
- Target resource requests and chart values to use in Phase 2

**Exit criteria:** go/no-go decision committed; `helm uninstall && kubectl delete ns temporal-spike` cleanup verified.

### Phase 1 — Approval gate end-to-end (≈2 weeks, no Postiz, no Temporal)

Deliverables:
1. `outreach` DB on LXC 114, dbmate migrations applied, trigger active.
2. Postgres role for n8n with INSERT/UPDATE on outreach tables, no DROP.
3. n8n credentials configured per the workflow-credential matrix.
4. Workflow A (manual webhook + ~5 writing-craft RSS feeds you pick).
5. Workflow B (Anthropic Sonnet 4.6 drafting, 3 variants, prompt v1 committed).
6. Workflow C (Slack notify + n8n form approval + hash recompute on edit).
7. Slack app installed in PlotLens workspace; `#plotlens-outreach` channel.
8. Credential-audit CI check (Python script diffing exported workflow JSON against the allowed-cred matrix).
9. Manual publishing: approved drafts get Slack-DMd to you for copy-paste.

**Exit criteria:**
- Approve ten drafts end-to-end including at least two edits and one rejection.
- Synthetic test: attempted publish of an unapproved or expired draft raises from the DB trigger.
- One full week running without manual DB intervention.

### Phase 2 — Postiz + Temporal in production (≈1 week)

- Deploy Temporal via ArgoCD to `plotlens-marketing` using the chart values from Phase 0 spike.
- Deploy Postiz via ArgoCD to `plotlens-marketing`: dedicated Redis StatefulSet, Postgres connection to LXC 114 `postiz` DB, object storage in MinIO (bucket `postiz-media`).
- Connect Postiz channels: X, Bluesky, Mastodon, LinkedIn. Reddit deferred.
- Workflow D (publish dispatcher) wired with Postiz API key.
- E2E test: discover → draft → approve → schedule via Postiz → `published_at` recorded.

**Exit criteria:** five original posts published via Postiz across at least two platforms successfully.

### Phase 3 — listmonk + SES (≈1 week)

- DNS for `plotlens.ai` zone configured.
- ClusterIssuer for `*.plotlens.ai` via cert-manager DNS-01 (DNS provider TBD by who runs the zone today; settled before phase start).
- listmonk deployed to `plotlens-marketing`, Postgres on LXC 114 (`listmonk` DB), SES SMTP credentials in Infisical.
- SES domain identity for `plotlens.ai` verified, DKIM + SPF + DMARC records published, SES production access requested and granted.
- listmonk public pages exposed at `news.plotlens.ai` (subscribe, confirm, unsubscribe, archive).
- Double-opt-in test list created, end-to-end signup → confirm → first newsletter sent.
- Cloud migration playbook documented in `docs/runbooks/listmonk-cloud-migration.md`.

**Exit criteria:** 10 confirmed test subscribers receive a real campaign; SES bounce rate <2%; unsubscribe link verified working.

### Phase 4 — Outcome logger + content calendar + visual channels (≈1 week)

- Workflow E (Postiz analytics → `outcomes`).
- UTM convention documented; signup attribution back to source post.
- Weekly content bucket calendar (Postiz-scheduled, drafted via Workflow B with `topic` set manually).
- Instagram + Threads connected via Postiz once professional accounts are set up.
- TikTok deferred until API audit. YouTube Shorts deferred until a video pipeline exists.

**Exit criteria:** one weekly content cycle completed end-to-end with attribution captured in `outcomes`.

## Cloud Migration Plan (listmonk)

**Trigger conditions** (any one):
1. Subscriber count exceeds ~5,000.
2. A multi-hour homelab outage affects an unsubscribe link.
3. Revenue-impacting product emails start flowing through listmonk.

**Target shape:**
- AWS App Runner (or Render) running the official `listmonk` container.
- RDS Postgres (or Aurora Serverless v2) for state.
- Same SES sender domain and DKIM keys — no re-verification needed.
- Same `news.plotlens.ai` DNS — flip CNAME from homelab to App Runner; subscriber URLs in vintage email stay valid.

**Procedure** (rehearsed during Phase 3, documented in `docs/runbooks/listmonk-cloud-migration.md`):
1. Provision RDS + App Runner with `listmonk` container, pointed at empty DB.
2. `pg_dump` from LXC 114 `listmonk` DB.
3. Restore dump to RDS.
4. Sync `uploads/` from MinIO to S3.
5. Update DNS `news.plotlens.ai` → App Runner.
6. Verify subscribe/confirm/unsubscribe round trips.

Estimated downtime if rehearsed: <30 min.

## Observability

**Prometheus scrapes** (existing kube-prometheus-stack): Temporal, Postiz, listmonk all expose metrics.

**Grafana dashboard:** `k8s/observability/dashboards/applications/plotlens-marketing.json`
- Outreach pipeline: items discovered/hr, drafts created/hr, approval latency (drafted → approved), approval rate by variant.
- Publish: jobs scheduled, jobs failed, hash-mismatch rejections (must be zero in steady state).
- Postiz: post creation latency, platform-specific failure rates.
- Temporal: workflow execution rate, task queue depth, worker count.
- listmonk: outbound queue depth, bounce rate, complaint rate.
- n8n workflow run health.

**Alertmanager rules** (added to `k8s/observability/`):
- Hash-mismatch rejection from `enforce_approval_match` > 0 → page (bug or attack).
- Postiz worker pod crashlooping → page.
- SES bounce rate > 5% → page.
- listmonk complaint rate > 0.1% → page (deliverability emergency).
- Approval queue > 20 drafts pending for >24h → low-priority notification (falling behind, not broken).

## Backups

Add four new entries to the existing Postgres backup job on LXC 114: `outreach`, `postiz`, `temporal`, `listmonk`. Daily logical dumps to MinIO bucket `cortech/db-backups/<dbname>/<date>.sql.gz`, 30-day retention.

Postiz object storage (MinIO bucket `postiz-media`) is mirrored by MinIO's existing snapshot job.

n8n workflow JSON is version-controlled in this repo plus n8n's existing weekly export to MinIO; no additional backup needed.

## Testing Strategy

- **Schema migrations:** dbmate `up` and `down` exercised in CI against a throwaway Postgres container before applying to LXC 114.
- **Trigger enforcement:** `apps/outreach-schema/db/tests/trigger_enforcement_test.sql` attempts inserts with mismatched hash, expired approval, and rejected decision — each must raise. Runs in CI.
- **Workflow credential audit:** `scripts/n8n/audit-credentials.py` runs in CI on every workflow export commit; fails the PR if any workflow references a credential outside its allowlist.
- **End-to-end smoke:** synthetic nightly n8n workflow hits the manual-paste webhook with a known URL; expects rows to appear in `outreach_items` → `drafts` → Slack notification within 5 min.
- **Postiz integration:** Postiz upstream tests cover the API; Phase 2 exit criteria includes a hand-tested approve-→-publish round trip.
- **No load testing for v1.** Single-founder scale.

## Runbooks

Added under `docs/runbooks/`:
- `temporal-spike-findings.md` (Phase 0 output)
- `outreach-db-recovery.md` (restoring from MinIO backup)
- `postiz-recovery.md` (re-syncing channel tokens, common failure modes)
- `listmonk-cloud-migration.md` (Phase 3 output)
- `revoke-approval.md` (how to expire an approval before its `expires_at`)
- `credential-audit.md` (running the CI check locally before pushing workflows)

## Acceptance Criteria

| ID | Criterion | Enforcement |
|---|---|---|
| AC-1 | AI cannot publish directly | No AI Agent node holds Postiz credentials; verified by `audit-credentials.py` |
| AC-2 | Every published item is human-approved | DB trigger requires `approvals.decision='approved'` |
| AC-3 | Approval is bound to exact text + destination | DB trigger requires `payload_hash = approved_content_hash` |
| AC-4 | Reddit replies are manual-only | Workflow D maps Reddit replies to `publish_mode='manual_required'` |
| AC-5 | Original scheduled posts can route via Postiz | Workflow D Postiz call gated on approval rows |
| AC-6 | Full audit trail | Every step is a DB row: `outreach_items` → `drafts` → `approvals` → `publish_jobs` → `outcomes` |
| AC-7 | No scraping-first discovery | Workflow A only accepts source_platform IN whitelist (CHECK constraint on `outreach_items`) |
| AC-8 | Channel-specific policy gates | Per-platform preflight checks in Workflow C (subreddit rules, IG professional account, TikTok audit state) |
| AC-9 | Approvals expire | DB default `expires_at = now() + 7 days`; trigger rejects expired |
| AC-10 | Workflow credential isolation | CI audit script blocks any PR that grants a workflow a forbidden credential |

## Open Questions

- `plotlens.ai` DNS provider for cert-manager DNS-01 ClusterIssuer (settled before Phase 3 starts).
- Whether the Phase 1 RSS feed list is configured via n8n workflow JSON or as a row table in `outreach` (decided during Phase 1 implementation).
- Whether to use n8n's Infisical-operator-synced K8s Secrets or direct Infisical CLI on the n8n LXC for secret injection (decided during Phase 1 implementation).

## References

- `CLAUDE.md` (repo conventions, homelab inventory)
- `docs/inventory.md` (Proxmox / K3s live inventory)
- Memory: `cortech-internal-vs-public-split` (architectural rule for internal vs user-facing services)
- Memory: `cortech-infisical-env-convention` (use `dev` env for new apps)
- Memory: `k3s-argocd-ingress-gotcha` (use Traefik IngressRoute, not plain Ingress, for ArgoCD-managed apps)
