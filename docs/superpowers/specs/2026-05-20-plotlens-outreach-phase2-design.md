# PlotLens Outreach Phase 2 — Postiz + Temporal in Production

**Status:** Design
**Author:** Jeremy Corbello
**Date:** 2026-05-20
**Predecessor:** Phase 1 build complete (branch `outreach/phase0-phase1`, operational validation in progress).
**Successor specs:** Phase 3 (listmonk + SES) and Phase 4 (Workflow E + visual channels) get their own specs when their predecessor ships.
**Original arc:** `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md`.

## Summary

Promote the PlotLens outreach pipeline from Phase 1's "approve then DM Jeremy to paste manually" publishing path to automated scheduling via Postiz. Deploy Postiz alongside its required Temporal dependency to a new K3s namespace `plotlens-marketing` under ArgoCD. The DB-enforced safety trigger from Phase 1 stays load-bearing; this phase adds an automated dispatcher that respects it.

AI still drafts. Humans still approve. The DB trigger still rejects mismatched payloads. Phase 2 makes the "approved → posted" leg automatic for supported channels and explicit/manual for the rest.

## Goals

1. Eliminate manual paste for posts to Postiz-supported channels.
2. Five posts published end-to-end across at least 2 channels, every post traceable to an `approvals` row.
3. Set the ArgoCD pattern for future marketing-stack services (listmonk in Phase 3).
4. Connect the lowest-friction channels first (Bluesky, Mastodon, r/PlotLens); start the slow OAuth approvals (X, LinkedIn) in parallel and pick them up as they land.

## Non-Goals

- No outcome analytics or UTM attribution — Phase 4.
- No listmonk, SES, or `*.plotlens.ai` DNS — Phase 3.
- No Instagram, Threads, TikTok, YouTube — Phase 4 (requires professional accounts + app audits).
- No automated Reddit comment replies — manual forever per AC-4 of the original spec.
- No content calendar / scheduling cadences — Phase 4.

## Scope

### In scope

1. K3s namespace `plotlens-marketing`.
2. Temporal deployed via ArgoCD using `temporal-server` Helm chart pinned to **0.74.0** (per Phase 0 spike findings in `docs/runbooks/temporal-spike-findings.md`).
3. Postiz deployed via ArgoCD with a dedicated in-cluster Redis StatefulSet, Postgres on LXC 114 `postiz` DB, and MinIO bucket `postiz-media`.
4. Postiz channel onboarding (in setup-complexity order): Bluesky → Mastodon → r/PlotLens → X → LinkedIn. X and LinkedIn slip to Phase 2.1 if their OAuth approvals lag.
5. **Workflow D** (n8n cron) — publish dispatcher. No LLM credentials; only the Postiz API key. Polls `publish_jobs WHERE status='ready'`, revalidates the content hash, calls Postiz API or routes to the existing manual-publish path.
6. Extension to **Workflow C's submit-approval handler** — the existing CTE that writes `approvals` is extended to also INSERT a `publish_jobs(status='ready')` row in the same transaction.
7. Two small schema migrations: `publish_jobs.attempt_count`/`sent_at` columns and adding `'published'` to `outreach_items.status` enum.
8. Living roadmap doc at `docs/superpowers/roadmaps/plotlens-outreach.md`.

### Out of scope (see "Future Phases" section)

See Non-Goals above. The "Future Phases" section captures the carrying constraints so Phase 3+ planning has the context it needs.

## Architecture

### Component placement (additions only — Phase 1 components untouched)

| Component | Where | URL | Source dir |
|---|---|---|---|
| Temporal (server, frontend, history, matching, worker, UI) | K3s `plotlens-marketing` | `temporal.corbello.io` (internal) | `apps/temporal/` |
| Postiz web + worker | K3s `plotlens-marketing` | `postiz.corbello.io` (admin) + `postiz-webhooks.corbello.io` (provider callbacks) | `apps/postiz/` |
| Postiz Redis | K3s `plotlens-marketing` (StatefulSet inside Postiz manifests) | n/a | inside `apps/postiz/` |
| Postiz Postgres | Existing LXC 114, new DB `postiz` + role `postiz_app` | n/a | new migration in `apps/outreach-schema/db/migrations/` |
| Temporal Postgres | Existing LXC 114, new DB `temporal` + role `temporal_app` | n/a | new migration |
| MinIO bucket | Existing LXC 123, new bucket `postiz-media` + dedicated user `postiz` | n/a | one-off manual setup (documented in plan) |

Two new ArgoCD Applications: `temporal` (sync-wave 0) and `postiz` (sync-wave 1).

### Why Temporal?

Postiz 2.12.0+ depends on Temporal for scheduled posts and background workflows. Temporal is deployed in Phase 2 **because Postiz needs it**, not because Workflow D moves to it. Workflow D stays as an n8n cron — preserves the original spec's security boundary (three separate n8n workflows: discover+draft / review / publish dispatcher) and the credential isolation that makes the audit script's job tractable.

The Phase 0 spike (`docs/runbooks/temporal-spike-findings.md`) validated the chart values and resource footprint we'll use here.

### Data flow (additions in **bold**)

```
draft writer (Workflow B)
  ↓ INSERT
drafts                                              [Phase 1, unchanged]
  ↓ status: needs_human_review
human approves (Workflow C submit handler)
  ↓ CTE atomic INSERT (approvals + publish_jobs)
approvals + publish_jobs(status='ready')            [PHASE 2: publish_jobs row]
  ↓ poll every 2 min
Workflow D (n8n)                                    [PHASE 2: new]
  ├─ revalidate sha256(text+dest+post_type) == approvals.approved_content_hash  (defense in depth)
  ├─ branch on publish_mode:
  │   ├─ postiz_scheduled / postiz_immediate → POST /api/v1/posts (Postiz)
  │   │     ↓ on 2xx
  │   │   publish_jobs.status='sent_to_postiz', postiz_post_id=<id>, sent_at=now()
  │   │     ↓ on 4xx/5xx
  │   │   publish_jobs.status='failed', failure_reason=<excerpt>, attempt_count++; retry next tick (≤3 attempts)
  │   └─ manual_required → status='manual_post_required' (Phase 1's outreach-manual-publish DM workflow handles delivery)
  ↓
outreach_items.status='published' (rollup when ALL publish_jobs for the item are sent/published/manual/failed-final)
```

The DB-enforced `enforce_approval_match` trigger from Phase 1 sits underneath all of this. Workflow D's hash recompute is defense-in-depth that catches drift before wasting a Postiz API call; the trigger is the hard guarantee that catches everything else.

### Workflow D node structure

1. **Schedule Trigger** — every 2 minutes.
2. **Postgres — Fetch Ready** — joins `publish_jobs + approvals + drafts`, returns the final text (using `COALESCE(approvals.edited_text, drafts.draft_text)`), `approved_destination`, `approved_post_type`, `approved_content_hash`, and `outreach_item_id`. Filters `status='ready' AND attempt_count < 3`. ORDER BY `scheduled_for NULLS FIRST, id`, LIMIT 20.
3. **Split In Batches** — batch size 1; output 1 = loop body (per the n8n v3 output-order gotcha from Phase 1).
4. **Code — Defense-in-depth hash recompute** — re-derives `sha256(finalText + destination + post_type)` using the same pure-JS SHA-256 helper as Phase 1's `Build Approval` node (cannot `require('crypto')` in n8n 2.9.4). Throws on mismatch before any API call.
5. **Switch — Branch on `publish_mode`** — 3 outputs: postiz_scheduled, postiz_immediate, manual_required.
6. **HTTP Request — Postiz Create Post** (for postiz_scheduled / postiz_immediate) — `POST {{$env.POSTIZ_BASE_URL}}/api/v1/posts` with bearer auth from the `postiz-api-key` credential. JSON body includes the channel-specific settings (Postiz docs spec the schema per platform).
7. **Postgres — Mark sent / failed** — `UPDATE publish_jobs SET status='sent_to_postiz', postiz_post_id=$1, sent_at=now() WHERE id=$2` on success; `UPDATE publish_jobs SET status='failed', failure_reason=$1, attempt_count=attempt_count+1 WHERE id=$2` on failure. Array-form `queryReplacement` per the Phase 1 gotcha.
8. **Postgres — Roll up outreach_items** — sets `outreach_items.status='published'` when ALL the item's `publish_jobs` reach a terminal state.

**Retry policy** is intentionally simple: `attempt_count < 3` gate. n8n's cron-every-2min IS the backoff. Phase 2.1 can introduce Temporal-driven exponential backoff if Postiz's actual failure modes warrant it; YAGNI until then.

## Schema changes

Two new dbmate migrations in `apps/outreach-schema/db/migrations/`:

| Migration | Change | Why |
|---|---|---|
| `20260520120000_publish_jobs_phase2_fields.sql` | `ALTER TABLE publish_jobs ADD COLUMN attempt_count INT NOT NULL DEFAULT 0, ADD COLUMN sent_at TIMESTAMPTZ` | Track retries + Postiz acknowledgment timestamp |
| `20260520120100_outreach_items_published_status.sql` | Drop existing `status` CHECK, re-add with `'published'` included | Rollup state needs to exist |

The `enforce_approval_match` trigger from Phase 1 is unchanged. Phase 1 trigger fixture tests must still pass after the new migrations.

**Out-of-band DBA setup** (not dbmate, because dbmate runs scoped to the `outreach` DB and these create new DBs at the cluster level):

- `CREATE DATABASE postiz; CREATE ROLE postiz_app WITH LOGIN PASSWORD '...'; GRANT ALL ON DATABASE postiz TO postiz_app;`
- `CREATE DATABASE temporal; CREATE ROLE temporal_app WITH LOGIN PASSWORD '...'; GRANT ALL ON DATABASE temporal TO temporal_app;`

These are documented as plan tasks with verification steps. Once created, Postiz and Temporal's own auto-setup containers manage their internal schemas.

## Channel onboarding

Ordered by setup complexity. Detailed step-by-step instructions live in the implementation plan; this section captures the order and the rationale.

| Order | Channel | Setup time | Blocker risk |
|---|---|---|---|
| 1 | **Bluesky** | ~30 min | None — open API, app-password auth |
| 2 | **Mastodon** | ~30 min | None — pick instance, create app, paste token |
| 3 | **r/PlotLens** | ~half-day | Subreddit already exists; need a Reddit OAuth app (`https://www.reddit.com/prefs/apps`) — fast |
| 4 | **X** | ~1 week | X Developer Account approval (1-7 days); OAuth2 + OAuth1 split per Postiz docs |
| 5 | **LinkedIn** | ~1-2 weeks | Marketing Developer Platform approval; fall back to "Share on LinkedIn" if denied |

Workflow D's E2E test unblocks at channel 2 (Bluesky + Mastodon both connected = two platforms). The original spec's exit criterion (5 posts across 2+ platforms) is reachable with just channels 1-3.

**r/PlotLens-specific rules** (from the supplemental subreddit design in the brainstorming dump):
- Original posts to r/PlotLens via Postiz: **allowed** (`destination_type=owned_community`, `publish_mode=postiz_scheduled`, `destination_post_type='post'`).
- Comment replies in r/PlotLens: **manual-only** (`publish_mode=manual_required`).
- Comment replies in any other subreddit: **manual-only forever** per AC-4.

Workflow D's Switch enforces this: a row with `destination_platform='reddit'` and `destination_post_type='comment'` must have `publish_mode='manual_required'` or it never reaches the Postiz API.

## ArgoCD deployment

### `apps/temporal/`

- `Chart.yaml` — wraps the `temporal-server` Helm chart 0.74.0 from `https://go.temporal.io/helm-charts`. Pin exact; v1.x dropped subchart options that the spike used.
- `values.yaml` — disable bundled Cassandra; external Postgres at `192.168.1.83:5432/temporal`; `setConfigFilePath=true`; `configMapsToMount=sprig`; resource requests sized per spike findings; UI exposed via Traefik `IngressRoute` at `temporal.corbello.io` (NOT plain `Ingress` — Phase 1 memory `k3s-argocd-ingress-gotcha` flags that plain Ingress hangs ArgoCD apps at `Progressing`).
- `application.yaml` — ArgoCD Application; auto-sync with `prune: true, selfHeal: true`; targetRevision `HEAD`; destination namespace `plotlens-marketing`; `syncOptions: [CreateNamespace=true]` on this Application only (Postiz inherits).

### `apps/postiz/`

- Either `Chart.yaml` if Postiz publishes an official Helm chart, or `kustomization.yaml` with raw manifests translated from the official docker-compose. Decision deferred to the plan once Postiz docs are checked at execution time.
- Contains: Postiz `Deployment` (web), Postiz `Deployment` (worker), Postiz Redis `StatefulSet` + headless `Service`, `ConfigMap` for non-secret env, `ExternalSecret` (or `SealedSecret` fallback) for secret env from Infisical, two `IngressRoute` resources (`postiz.corbello.io`, `postiz-webhooks.corbello.io`).
- `application.yaml` — sync-wave 1 (Temporal first); auto-sync.

### Sync ordering

First install: sync Temporal alone via ArgoCD UI / CLI, wait until `Healthy`, then sync Postiz. Steady state: both auto-sync independently.

## Secrets

All Phase 2 secrets in Infisical PlotLens project (`db72a923-3cd8-4636-b1ff-80845dc070ca`) env `dev` per the homelab `dev`-everywhere convention.

| Secret name | Used by | Source |
|---|---|---|
| `POSTIZ_DATABASE_URL` | Postiz | manual DBA creates `postiz` DB + role |
| `POSTIZ_REDIS_URL` | Postiz | in-cluster service DNS, fixed in manifests; not strictly a "secret" but stored for convenience |
| `POSTIZ_JWT_SECRET` | Postiz | `openssl rand -base64 32` |
| `POSTIZ_ADMIN_PASSWORD` | Postiz | `openssl rand -base64 24` |
| `POSTIZ_API_KEY` | Workflow D | generated via Postiz UI after first login |
| `POSTIZ_BASE_URL` | Workflow D | `https://postiz.corbello.io` |
| `POSTIZ_MINIO_ACCESS_KEY` | Postiz | dedicated MinIO user `postiz` scoped to `postiz-media/*` |
| `POSTIZ_MINIO_SECRET_KEY` | Postiz | same |
| `TEMPORAL_DATABASE_URL` | Temporal | manual DBA creates `temporal` DB + role |

**Per-channel OAuth credentials** (Bluesky app password, Mastodon access token, Reddit client ID/secret, X four-tuple, LinkedIn client ID/secret) live in Postiz's own database after the in-UI OAuth flow. We don't duplicate them in Infisical. Recovery path = backup of the `postiz` Postgres DB.

**Injection pattern:** External Secrets Operator (ESO) pulling from Infisical → K8s `Secret` → pod env. If ESO is not installed in the cluster, fall back to `SealedSecret` with the existing cluster sealing key. The plan's first task verifies which pattern is active and adapts.

## Backups

- **Postiz DB** added to the existing LXC 114 pg_dump cron. Dump: `s3://cortech/db-backups/postiz/<YYYY-MM-DD>.sql.gz`. 30-day retention.
- **Temporal DB** added to the same cron. Less critical (active workflow state regenerates from Postiz scheduling), but cheap.
- **`postiz-media` bucket** — MinIO bucket lifecycle handles it; no separate backup. Media is recoverable from source if lost.

## Observability

**Prometheus scrapes** (existing kube-prometheus-stack): Temporal exposes `:9090/metrics`; Postiz worker exposes Prom metrics. Each app's manifests include a `ServiceMonitor` so the operator picks them up automatically.

**Grafana dashboard:** new ConfigMap `k8s/observability/dashboards/applications/plotlens-marketing.json` (label `grafana_dashboard: "1"` for the sidecar auto-discovery pattern). Panels:

- **Outreach pipeline** (carried forward): items discovered/hr, drafts/hr, approval latency (drafted→approved), approval rate by variant.
- **Publish:** `publish_jobs` count by status (ready / sent_to_postiz / manual_post_required / failed), Workflow D execution duration p50/p95, Postiz API call duration + error rate.
- **Safety:** `enforce_approval_match` trigger rejection count — **MUST be 0 in steady state; alertable**.
- **Postiz:** per-platform post creation latency + per-platform failure rate.
- **Temporal:** workflow execution count, worker pool size, queue depth (mostly a health pulse for Postiz's internal use).

**Alerts** (added to existing Alertmanager config):

| Condition | Severity | Route |
|---|---|---|
| `enforce_approval_match` trigger rejection (any) | P1 | Page Jeremy |
| `publish_jobs.status='failed'` count > 0 sustained ≥5 min | P2 | `#plotlens-outreach` Slack |
| `publish_jobs WHERE status='ready' AND created_at < now() - INTERVAL '15 min'` ≥1 | P2 | `#plotlens-outreach` Slack — dispatcher stalled |
| Postiz pod restart > 1 in 10 min | P3 | `#plotlens-outreach` Slack |
| Temporal pod restart > 1 in 10 min | P3 | `#plotlens-outreach` Slack |

## Testing strategy

### Schema tests

Phase 1's `apps/outreach-schema/db/tests/run_tests.sh` continues to pass after the new migrations. Phase 2 adds:

- Test that `publish_jobs.attempt_count` increments only on UPDATE-to-failed paths, not on UPDATE-to-sent.
- Test that `outreach_items.status='published'` rollup fires when ALL related `publish_jobs` reach terminal state and not before.
- Regression: synthetic `publish_jobs` INSERT with valid hash still passes `enforce_approval_match`.

### Workflow D smoke tests

Per-branch shell scripts, same pattern as Phase 1 smoke verification:

- `tests/workflow-d/test_hash_recompute.sh` — feed a row with deliberately-wrong hash, confirm Workflow D throws before any Postiz API call (and no Postiz call recorded in the Postiz access log).
- `tests/workflow-d/test_retry_cap.sh` — preset `attempt_count=3`, confirm Workflow D ignores the row.
- `tests/workflow-d/test_manual_required_branch.sh` — feed a `publish_mode='manual_required'` row, confirm status flips to `manual_post_required` without Postiz call; confirm Phase 1's manual-publish workflow picks it up next tick.

### Integration test (sandbox Postiz)

Before connecting any real social channel, point Postiz at a single throwaway Bluesky account (fastest setup). Run end-to-end: manual Discover webhook → Draft → Approve → Workflow D → Postiz → Bluesky post visible. This validates the full chain without spamming real channels.

### Audit script

`scripts/n8n/audit_credentials.py` (already exists from Phase 1) gets:

- New workflow entry `publish-dispatcher.json` with allow `[outreach-db-n8n, postiz-api-key]`.
- New forbidden rule: any credential matching the LLM provider IDs (anthropic-api-key, openai-api-key, etc.) on `publish-dispatcher.json` is a hard CI fail. This is the original spec's security-boundary "publish dispatcher does not call LLMs" enforced procedurally.

### CI

Existing `.github/workflows/outreach-ci.yml` (schema + audit jobs) continues. Phase 2 adds a manifests-lint job: `helm template apps/temporal/ | kubectl apply --dry-run=client -f -` and the same for `apps/postiz/`. Full kind-cluster validation is out of scope for Phase 2; the dry-run catches schema errors which is the main risk.

## Exit criteria

Phase 2 is done when ALL of the following hold:

1. ArgoCD shows both `temporal` and `postiz` Applications `Healthy` + `Synced` for 24h continuous.
2. Three channels connected and verified end-to-end via Postiz UI smoke posts: **Bluesky, Mastodon, r/PlotLens**. (X and LinkedIn are bonus; they slip to Phase 2.1 if their OAuth approvals stall.)
3. **Five distinct posts published via Postiz across at least 2 platforms**, all originating from approvals — every post traceable from `publish_jobs.postiz_post_id` back to `approvals.id`.
4. All synthetic trigger-bypass tests pass on the post-migration schema.
5. **`enforce_approval_match` trigger rejections = 0** for the entire Phase 2 post-deploy period in Grafana. Non-zero means something attempted to publish unapproved content; investigate before tagging.
6. Workflow D execution success rate ≥ 99% over a 48h window with real load.
7. One full week running without manual DB intervention, paralleling Phase 1's exit gate.
8. Living roadmap doc at `docs/superpowers/roadmaps/plotlens-outreach.md` exists, is current, and reflects Phase 2 status.
9. Release tagged `outreach-phase2-shipped` once 1-8 hold AND Phase 1 has also been tagged.

## Risks + mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| X / LinkedIn OAuth approval delays beyond Phase 2 timebox | High | Low | Exit criterion #2 requires only 3 channels (Bluesky/Mastodon/r-PlotLens). X + LinkedIn slip to Phase 2.1. |
| Postiz has no published Helm chart; raw Kustomize required | Medium | Low | Postiz's docker-compose is mechanical to translate. Pin Postiz image SHA, not `latest`. |
| Temporal chart 0.74.0 incompatible with Postiz's required Temporal API version | Low | High | Phase 0 spike validated 0.74.0 on the cluster. Verify Postiz docs' minimum Temporal version before deploy. Worst case: bump chart to a newer Postiz-compatible version with regression testing. |
| `publish_jobs` row created at approval time but Workflow D never picks it up (silent stall) | Low | High | Alertmanager rule pages on any `status='ready'` row older than 15 minutes. |
| Postiz API key leaked into a non-publish workflow | Medium | Critical (defeats security boundary) | CI audit script forbids the credential anywhere except `publish-dispatcher.json`. Hard fail. |
| Workflow D retry cap too aggressive (3 attempts) — real Postiz transient errors lose posts | Medium | Medium | Failed posts stay in DB visible. Manual re-queue procedure documented in runbook. Phase 2.1 can introduce Temporal-driven retries if this becomes a pattern. |
| Marketing Dev Platform approval denied → LinkedIn cannot post as Company Page | Medium | Low | Fallback path documented: use "Share on LinkedIn" only (posts as personal profile). Add Company Page later when approval lands. |

## Operational runbooks (added in Phase 2)

- `docs/runbooks/postiz-channel-onboarding.md` — per-channel OAuth setup steps (the long-form version of Section 3 above).
- `docs/runbooks/postiz-failed-job-recovery.md` — how to re-queue a `publish_jobs.status='failed'` row, when to skip vs retry.
- `docs/runbooks/temporal-restart.md` — Temporal pod restart procedure, what state survives, how to verify after.

## Future Phases — context, not commitments

The full arc is in the original outreach stack design (`docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md`). The living roadmap at `docs/superpowers/roadmaps/plotlens-outreach.md` is the canonical place to look up current status and pending decisions.

### Phase 3 — listmonk + SES (~1 week)

Estimated start: 2+ weeks after Phase 2 stable.

- New app dir `apps/listmonk/`, same ArgoCD pattern as Phase 2.
- `plotlens-marketing` namespace gets a third Application.
- DNS for the `plotlens.ai` zone configured.
- ClusterIssuer for `*.plotlens.ai` via cert-manager DNS-01.
- SES domain identity verified; DKIM + SPF + DMARC records published; SES production access requested and granted.
- listmonk public pages at `news.plotlens.ai`.
- Cloud migration playbook rehearsed and documented at `docs/runbooks/listmonk-cloud-migration.md`.
- **Exit:** 10 confirmed test subscribers receive a real campaign; SES bounce rate < 2%; unsubscribe link verified.

**Decisions to settle before Phase 3 starts:**
- Which DNS provider hosts `plotlens.ai` (affects DNS-01 challenge config).
- Which SES region.
- Subscriber list segmentation: one global list, or per-persona (Maya / James / Priya / Aria / Marcus / Elena / editor / studio)?

### Phase 4 — Workflow E + visual channels (~1 week)

- Workflow E: hourly cron polling Postiz analytics → `outcomes` rows.
- UTM convention documented; signup attribution back to source post via listmonk.
- Weekly content calendar (Postiz-scheduled, drafted via Workflow B with topic set manually).
- Instagram + Threads connected once professional accounts are set up.
- TikTok deferred until app audit (private-viewing-only restriction); YouTube Shorts deferred until a video pipeline exists.
- **Exit:** one weekly content cycle end-to-end with attribution captured in `outcomes`.

### Cloud migration (listmonk → AWS App Runner + RDS)

**Trigger conditions** (any one):
1. Subscriber count exceeds ~5,000.
2. Multi-hour homelab outage affects an unsubscribe link.
3. Revenue-impacting product emails flow through listmonk.

**Procedure** rehearsed during Phase 3; downtime estimate < 30 min if rehearsed:
1. Provision RDS + App Runner with `listmonk` container, pointed at empty DB.
2. `pg_dump` from LXC 114 `listmonk` DB.
3. Restore to RDS.
4. Sync `uploads/` from MinIO to S3.
5. DNS `news.plotlens.ai` → App Runner.
6. Verify subscribe / confirm / unsubscribe round trips.

### Carrying constraints (Phase 2 decisions that affect Phase 3+)

- `plotlens-marketing` namespace exists; Phases 3-4 add Applications to it, not new namespaces.
- LXC 114 Postgres now hosts 4 outreach-related DBs by Phase 3 (`outreach`, `postiz`, `temporal`, `listmonk`). Watch shared connection pool. Phase 4 may need pgbouncer if connection count grows.
- ArgoCD `apps/<service>/` pattern locked for the marketing stack — Phase 3's listmonk follows it.
- Workflow D's retry policy is `attempt_count < 3` with n8n-cron-as-backoff. Phase 4 may revisit if Postiz failure modes get nuanced.
- The `outcomes` table is now multi-purpose: Phase 1 uses it for notification dedup (`kind='notified'`, `kind='manual_dm_sent'`), Phase 4's Workflow E will write `kind='analytics_<platform>'` rows. The `notes::jsonb->>'kind'` namespace must not collide; new kinds should be documented in the roadmap doc as they're added.

## Acceptance criteria (Phase 2 specific)

AC-1 through AC-8 from the original spec all continue to apply. Phase 2 adds:

- **AC-P2-1:** Workflow D never references LLM credentials. Audit script hard-fails on violation.
- **AC-P2-2:** Every `publish_jobs.status='sent_to_postiz'` row has a corresponding non-null `postiz_post_id`.
- **AC-P2-3:** Every `outreach_items.status='published'` rollup is preceded by all related `publish_jobs` reaching a terminal state. (Implementation responsibility: the rollup UPDATE in Workflow D node 8.)
- **AC-P2-4:** A row in `publish_jobs.status='ready'` older than 15 minutes is paged via alert. (Implementation responsibility: Alertmanager rule.)

## Open questions

- **Postiz Helm chart availability:** Whether Postiz publishes an official Helm chart determines `apps/postiz/` shape (Helm vs Kustomize). Resolved at execution time by checking Postiz docs.
- **ESO vs SealedSecrets in this cluster:** Verified at execution time before authoring Postiz manifests.
- **Workflow D node placement on LXC 112:** Phase 1 added several env vars to the n8n systemd drop-in (`SLACK_SIGNING_SECRET`, `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`, `SLACK_OUTREACH_OPERATOR_USER_ID`). Phase 2 will need to add `POSTIZ_API_KEY` and `POSTIZ_BASE_URL`. Confirmed plan task. Phase 2.5 / Phase 3 should evaluate migrating these out of systemd env into n8n credentials.

## References

- Original arc: `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md`
- Phase 0 spike: `docs/runbooks/temporal-spike-findings.md`
- Phase 1 plan (predecessor): `docs/superpowers/plans/2026-05-19-plotlens-outreach-phase0-and-phase1.md`
- Phase 1 HANDOFF (current branch state): `HANDOFF.md`
- Postiz docs: https://docs.postiz.com/
- Temporal Helm: https://go.temporal.io/helm-charts
- ArgoCD pattern: see existing `apps/` in this repo (Harbor, Rancher, Infisical, SonarQube)
