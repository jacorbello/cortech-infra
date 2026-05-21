# PlotLens Outreach — Session Handoff

**As of:** 2026-05-21, end-of-Phase-2-build + Phase 2.1 schema cleanup LANDED (publish_jobs.created_at added, approvals.approved_platform split out, Workflow C dropdown sourced from live Postiz integrations, hash payload includes platform, Workflow C+D deployed to LXC 112 and smoke-tested end-to-end)
**Branch:** `outreach/phase0-phase1` (1 branch, 90 commits ahead of `main`, pushed)
**Draft PR:** https://github.com/jacorbello/cortech-infra/pull/18 (CI at HEAD `7a7fdc3` covers the Phase 2.1 schema + workflow JSON changes — schema / audit / sha256-audit / manifests-lint)
**Phase 1 spec:** `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md`
**Phase 1 plan:** `docs/superpowers/plans/2026-05-19-plotlens-outreach-phase0-and-phase1.md`
**Phase 2 spec:** `docs/superpowers/specs/2026-05-20-plotlens-outreach-phase2-design.md`
**Phase 2 plan:** `docs/superpowers/plans/2026-05-20-plotlens-outreach-phase2.md`
**Living roadmap:** `docs/superpowers/roadmaps/plotlens-outreach.md`

Read this file first on any session resume. Safe to delete once Phase 2 is tagged.

## Where we are right now

**Phase 1:** ALL 34 tasks BUILT. Operational validation (10 real items end-to-end) NOT done. NOT tagged.

**Phase 2:** T1-T29 done + Phase 2.1 schema cleanup done (A1-A3 + B1-B7 + B5.5). T30 is the exit gate — it can't be tagged until:
1. Phase 1 is tagged first (exit criterion 9).
2. At least 5 production publish_jobs rows succeed (we have 1 legitimate Postiz post from T25 + 1 synthetic Bluesky post from B7 smoke test that needs cleanup).
3. ArgoCD `temporal` + `postiz` Applications stay Synced/Healthy for 24h (we're well under that — Postiz revision changed at `c4bb719` during T25 and again at `56412ff` for the Postiz API payload fix).

### Phase 2 task status (final)

| Task | Status | Notes |
|---|---|---|
| T1-T24 | ✅ | (see prior handoff snapshot in git history) |
| T25 | ✅ | E2E test succeeded — publish_jobs row 62 → `sent_to_postiz`, postiz_post_id `cmpel07680002j0au2phuim4q`, outreach_items 1046 → `published` |
| T26 | ✅ | Grafana dashboard `k8s/observability/dashboards/applications/plotlens-marketing.yaml` (10 panels — pod health, mem/cpu, Loki errors, restarts; DB panels deferred to Phase 2.1) |
| T27 | ✅ | `k8s/observability/rules/plotlens-marketing-alerts.yaml` (5 alerts — pod crash loops × 2, NotReady, stalled publish_jobs, sustained failures) |
| T28 | ✅ | 3 runbooks committed: `docs/runbooks/postiz-channel-onboarding.md`, `postiz-failed-job-recovery.md`, `temporal-restart.md` |
| T29 | ✅ | `.github/workflows/outreach-ci.yml` now has `manifests-lint` job (Postiz Kustomize + Temporal Helm template + extras; built-in-kinds filter for CRD compatibility) |
| **T30** | **⏳ pending** | Awaiting Phase 1 tag + 5 production posts + 24h ArgoCD stability |

### Phase 2.1 schema cleanup (final)

| Task | Status | Notes |
|---|---|---|
| A1 | ✅ | `publish_jobs.created_at` column + backfill (commit `3f9c2e2`, migration `20260521130000_publish_jobs_add_created_at.sql`). NOT NULL DEFAULT now() with index on `(status, created_at)`. |
| A2 | ✅ | postgres_exporter custom query simplified — dropped `approvals` JOIN, now reads `publish_jobs.created_at` directly (commit `385b821`). |
| A3 | ✅ | `docs/runbooks/postiz-failed-job-recovery.md` updated to drop the JOIN (commit `6a0476c`). |
| B1 | ✅ | `approvals.approved_platform` column added with CHECK constraint (`bluesky`, `mastodon`, `linkedin`, `x`, `reddit`) + backfill from existing rows (commit `fe3c90e`, migration `20260521130100_approvals_add_approved_platform.sql`). |
| B2 | ✅ | Workflow C `Fetch Postiz Integrations` HTTP node fetches live integration list from `/api/public/v1/integrations` (commit `61f6eec` + comment-refresh fixup `a144ba8`). |
| B3 | ✅ | Workflow C approval form renders a dynamic platform dropdown sourced from the Postiz integrations response (commit `4f1f3e0`). |
| B4 | ✅ | Both Workflow C (`Build Approval`) and Workflow D (`Verify Hash`) include `approved_platform` in the SHA-256 hash payload — payload is now 6 fields instead of 5 (commit `cea11ca`). |
| B5 | ✅ | Workflow C `Write Approval (CTE)` `pj` CTE now sets `publish_jobs.destination_platform := ins.approved_platform` — semantic string (`bluesky`) instead of the integration ID duplicate (commit `87056b4`). |
| B5.5 | ✅ | `Write Slack Approval (CTE)` patched to insert `approved_platform='bluesky'` (defaulted; Slack quick-approve still has no destination override affordance) so it satisfies the new NOT NULL constraint (commit `7a7fdc3`). |
| B6 | ✅ | Workflow C + D deployed to LXC 112 n8n via `n8n import:workflow` + `n8n.service` restart. No git artifact. |
| B7 | ✅ | End-to-end smoke test: synthetic publish_jobs row dispatched through Workflow D's Verify Hash with the new 6-field payload, posted live to Bluesky (post id `cmpfkq5x80003j0aulvbz98h4`) — needs cleanup, see TODO. |

## Resume procedure (next steps in order)

Steps 1 + 2 of the prior procedure are done. Remaining work:

1. ~~**Workflow C `destination_account` CTE fix.**~~ ✅ Done (commit `26fc6b7`). Workflow C's `pj` CTE now sets both `destination_platform` and `destination_account` to `ins.approved_destination` (the Postiz integration ID). Workflow D only reads `destination_account`; `destination_platform` is selected by Fetch Ready but never consumed. Imported + active on LXC 112. Cleaner field-split refactor still deferred to Phase 2.1.
2. ~~**Open a PR.**~~ ✅ Done. PR #18 (https://github.com/jacorbello/cortech-infra/pull/18), draft, all 3 CI checks green:
   - schema (40s) — needed `postgresql-client` installed on `cortech-infra-runner` (commit `78d4ab6`); latent bug in `run_tests.sh` that false-passes when psql is missing has been fixed in the same push.
   - audit (39s) — Workflow D credential audit passed.
   - manifests-lint (11s) — `kubectl apply --dry-run=client` was dropped because GitHub-hosted runners still do server-side API discovery even with `--validate=false`. Final form is kustomize build + helm template + Python YAML parse + kind allow-list + hard fail on missing kind/apiVersion (commit `a67d2f8`).
3. **Phase 1 operational validation.** Use the system for ≥1 week, process ≥10 real outreach items end-to-end. Once done, tag Phase 1: `git tag -a outreach-phase1-shipped -m "Phase 1: approval gate end-to-end"`. This unblocks T30. **This is the only thing blocking Phase 2 tag.**

4. **Phase 2 T30 (tag).** After step 3 completes AND there are ≥5 production posts in `sent_to_postiz` AND the ArgoCD `temporal` + `postiz` Applications stay Synced/Healthy for a full 24h window:
   ```bash
   ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
   psql "$ADMIN_URL" -c "SELECT COUNT(*) FROM publish_jobs WHERE status='sent_to_postiz';"
   ssh root@192.168.1.52 "kubectl get applications -n argocd temporal postiz"
   ```
   Then merge PR #18 (`gh pr merge 18 --squash`), switch `apps/temporal/argocd-application.yaml` + `apps/postiz/argocd-application.yaml` `targetRevision` from `outreach/phase0-phase1` to `main`/`HEAD`, and `git tag -a outreach-phase2-shipped -m "Phase 2: Postiz + Temporal + Workflow D"`.

5. **Phase 2.1 follow-ups (deferred items, see roadmap).** None are urgent; act when traffic warrants:
   - **Reddit Devvit revisit** if Reddit relaxes the Responsible Builder Policy.
   - **X — deferred indefinitely** (user-confirmed 2026-05-21). Root cause of the "Could not connect to the platform" error fully diagnosed: Postiz X provider needs `X_API_KEY` + `X_API_SECRET` (OAuth 1.0a Consumer Keys); deployment doesn't supply them; backend `try/catch` at `apps/backend/src/api/routes/integrations.controller.ts:225-245` swallows the error and returns `200 OK` with `{"err":true}`. Posting on X requires a paid Basic plan ($100/mo since Feb 2023; free tier is read-only). Full wiring instructions captured in `docs/runbooks/postiz-channel-onboarding.md` "### X" section if we ever revisit.
   - **LinkedIn** when Marketing Developer Platform approval comes through.
   - ~~n8n pure-JS SHA-256 retroactive audit~~ ✅ Done commit `55c8858`. All 5 copies are bit-for-bit identical (md5 `d9d19d56...`); RFC 6234 Appendix B + NIST 1M-`a` + padding/block boundaries + multibyte UTF-8 all pass. Audit lives at `apps/outreach-workflows/tests/sha256-audit/audit.js` and runs in CI as the `sha256-audit` job.
   - ~~Split `approved_destination` into `approved_platform` + `approved_destination` on the approval form~~ ✅ Done commits `fe3c90e` (B1 schema) → `4f1f3e0` (B3 dropdown) → `87056b4` (B5 CTE) → `7a7fdc3` (B5.5 Slack path). `publish_jobs.destination_platform` now carries the semantic string (`bluesky`) and `destination_account` carries the integration ID.
   - ~~**Decide whether Slack quick-approve should enqueue publishing**~~ ✅ DONE commit `e205db1` (option 1 chosen 2026-05-21). Slack approve-click dispatches via the `pj` CTE (gated on non-empty `suggested_destination` and `decision='approved'`). Hash payload includes platform. HTTP Confirm Approval ephemeral message differentiates dispatched/triage-only/rejected. Limitation: platform hardcoded to 'bluesky' since Slack buttons don't carry a platform selector.
   - ~~`publish_jobs.created_at` migration~~ ✅ Done commits `3f9c2e2` (A1 column) → `385b821` (A2 exporter query) → `6a0476c` (A3 runbook). JOIN removed from both consumers; `created_at` is now NOT NULL DEFAULT now() with index on `(status, created_at)`.

## Phase 2 architecture at a glance

```
LXC 100 NGINX (TLS) ←→ K3s Traefik (192.168.1.90 NodePort)
                              ↓
                       plotlens-marketing namespace
                       ├── Temporal (Helm chart 0.74.0, Synced/Healthy)
                       │     ├── frontend, history, matching, worker, web
                       │     └── Postgres on LXC 114 (192.168.1.83) dbs: temporal, temporal_visibility
                       └── Postiz (Kustomize, Synced/Healthy)
                             ├── postiz Deployment (web port 5000 + backend port 3000, 8Gi mem)
                             ├── postiz-redis StatefulSet (5Gi PVC)
                             └── Postgres on LXC 114 db: postiz
                                   ↑
                                   uses Temporal at temporal-frontend.plotlens-marketing.svc.cluster.local:7233

Public URLs (all TLS via certbot on LXC 100):
- temporal.corbello.io   (Temporal Web UI)
- postiz.corbello.io     (Postiz admin)
- postiz-webhooks.corbello.io  (Postiz provider callbacks)
```

## Live system state

### n8n workflows on LXC 112 (all active)

| Workflow ID | Name | Trigger | Phase |
|---|---|---|---|
| `dScvr0utReAcHW01` | outreach-discover | Webhook + RSS every 30min | 1 |
| `dRaFtWfOutreach001` | outreach-draft | Schedule every 5min | 1 |
| `rEv1eWoUtReAcH001` | outreach-review-notify | Schedule 2min + 3 webhooks | 1 + 2 (CTE extended in T18) |
| `eXp1rEsTaLeWf001` | outreach-expire-stale | Daily 03:00 UTC | 1 |
| `mAnUaLpUbLiSh0001` | outreach-manual-publish | Schedule 2min | 1 |
| `sMoKeOutreachW001` | outreach-smoke | Daily 09:00 UTC | 1 |
| `pUbLiShDiSpAtCh01` | outreach-publish-dispatcher | Schedule 2min | 2 (✅ T25 SUCCESS) |

### n8n credentials wired

| Name | Type | ID | Notes |
|---|---|---|---|
| outreach-db-n8n | postgres | fOZmso5kyXr6Agdn | |
| discover-webhook-secret | httpHeaderAuth | R8FUCCmGLkzJdEPB | |
| anthropic-api-key | anthropicApi | KHgVcFOKeWW5rMme | |
| slack-bot-token | slackApi | o9pysvcgZQFhoOLP | |
| n8n-form-auth | httpBasicAuth | wp5foUcxmwrXaaDk | |
| **postiz-api-key** | httpHeaderAuth | **pZtZApIkEy00000A** | **Raw key (no `Bearer ` prefix) — fixed T25** |

### LXC 112 systemd drop-in `/etc/systemd/system/n8n.service.d/slack-env.conf`

```
[Service]
Environment=SLACK_OUTREACH_CHANNEL_ID=C0B4SUTP8R4
Environment=SLACK_SIGNING_SECRET=<from Infisical>
Environment=N8N_BLOCK_ENV_ACCESS_IN_NODE=false
Environment=SLACK_OUTREACH_OPERATOR_USER_ID=U0AQ8L39DFA
Environment=POSTIZ_API_KEY=<from Infisical>
Environment=POSTIZ_API_BASE_URL=https://postiz.corbello.io/api/public/v1
```

Not in git. If LXC 112 is rebuilt, restore this file before reactivating workflows. (Phase 4 idea: migrate these into n8n Credentials so we can drop `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`.)

### postgres_exporter (observability namespace)

`k8s/observability/exporters/postgres-outreach-exporter/` — 5 manifests applied, pod running on k3s-wrk-3, scraped by kube-prom-stack via ServiceMonitor (`release: prometheus` label). Connects to LXC 114 outreach DB via the `outreach_n8n` role (URL synced from Infisical PlotLens project, env=dev, root path, by InfisicalSecret `postgres-outreach-exporter`). Six custom-query gauges live in Prometheus:

| Metric | Current value | Notes |
|---|---|---|
| `outreach_publish_jobs_ready_oldest_age_seconds` | 0 | gauge; reads `publish_jobs.created_at` directly (Phase 2.1 A1+A2 dropped the `approvals` JOIN) |
| `outreach_publish_jobs_ready_count` | 0 | |
| `outreach_publish_jobs_failed` | 0 | row 47 abandoned (commit `f2ae505`) — alert disarmed |
| `outreach_publish_jobs_sent_to_postiz` | 1 | row 62 (T25 SUCCESS) |
| `outreach_publish_jobs_manual_required` | 0 | |
| `outreach_publish_jobs_abandoned` | 1 | row 47 — pre-CTE-fix legacy with hash-mismatch from `>>>` mod-32 bug |

NOT pg_-prefixed — only built-in collectors get that. See memory `postgres-exporter-custom-query-prefix`.

### Postgres on LXC 114 (192.168.1.83)

| DB | Owner | Phase | Purpose |
|---|---|---|---|
| outreach | outreach_admin / outreach_n8n | 1 | All outreach tables + `enforce_approval_match` trigger |
| postiz | postiz_app | 2 | Postiz's own schema (auto-managed) |
| temporal | temporal_app | 2 | Temporal's primary persistence |
| temporal_visibility | temporal_app | 2 | Temporal's visibility queries |

### Postiz integrations (live)

| Secret name | Postiz channel ID | Account |
|---|---|---|
| POSTIZ_INTEGRATION_BLUESKY | cmpefkzmt0001kbb1plpudyo3 | jacorbello.bsky.social (personal) |
| POSTIZ_INTEGRATION_BLUESKY_PLOTLENS | cmpefsrxp0005kbb1ttpbkjnf | plotlens.bsky.social (brand — default for outreach) |
| POSTIZ_INTEGRATION_MASTODON | cmpegkub20001j0auhv9epe72 | @plotlens@mastodon.social |

When approving drafts via the Slack form, paste the channel ID into `approved_destination`. Brand handle = preferred default.

### Infisical PlotLens project `db72a923-3cd8-4636-b1ff-80845dc070ca` env `dev`

Root path: ANTHROPIC_API_KEY, OUTREACH_DB_*_URL, DISCOVER_WEBHOOK_SECRET, N8N_FORM_AUTH_USER/PASSWORD, SLACK_*, SLACK_OUTREACH_OPERATOR_USER_ID.

`/postiz` path:
- POSTIZ_DATABASE_PASSWORD, POSTIZ_DATABASE_URL
- POSTIZ_REDIS_URL (in-cluster DNS)
- POSTIZ_JWT_SECRET, POSTIZ_ADMIN_PASSWORD (unused after T14 signup)
- POSTIZ_MINIO_ACCESS_KEY, POSTIZ_MINIO_SECRET_KEY, POSTIZ_MINIO_ENDPOINT
- POSTIZ_MAIN_URL, POSTIZ_FRONTEND_URL, POSTIZ_NEXT_PUBLIC_BACKEND_URL
- POSTIZ_API_KEY, POSTIZ_API_BASE_URL (= `https://postiz.corbello.io/api/public/v1`), POSTIZ_MCP_KEY
- POSTIZ_INTEGRATION_BLUESKY, POSTIZ_INTEGRATION_BLUESKY_PLOTLENS, POSTIZ_INTEGRATION_MASTODON
- MASTODON_CLIENT_ID, MASTODON_CLIENT_SECRET, MASTODON_URL

`/temporal` path:
- TEMPORAL_DATABASE_PASSWORD

## Open issues / known bugs

### 1. ~~publish_jobs.destination_account is empty after Workflow C writes it~~ ✅ FIXED commit `26fc6b7`

Workflow C's `pj` CTE in `Write Approval (CTE)` now sets both `destination_platform` and `destination_account` to `ins.approved_destination`. Workflow D's Fetch Ready selects `destination_platform` but never reads it — only `destination_account` is passed to the Postiz HTTP node as `integration.id`. The CTE was imported into LXC 112 n8n and the workflow re-activated; the n8n service was restarted.

**Note:** `Write Slack Approval (CTE)` (the Slack quick-approve handler) has NO `pj` CTE at all — Slack-button approvals don't enqueue publishing, only the form does. Whether to add a `pj` CTE there (so Slack approves can dispatch too) is a Phase 2.1 design question.

**Phase 2.1 cleanup:** split `approved_destination` into `approved_platform` (human-readable: `bluesky`) AND `approved_destination` (Postiz integration ID) on the approval form so `publish_jobs.destination_platform` carries semantic value again. Today both columns hold the integration ID.

### 2. SHA-256 padding bug — FIXED in T25, retroactive audit pending

Commit `c4bb719` fixed a JavaScript `>>>` modulo-32 shift bug in the bit-length-encoding part of the SHA-256 implementation. Build Approval (Workflow C) was already using the correct hardcoded `0,0,0,0,(bitLen>>>24)…` padding; Verify Hash (Workflow D) had a buggy loop `for (let i = 7; i >= 0; i--) bytes.push((bitLen >>> (i*8)) & 0xff)` — `bitLen >>> 56` evaluates to `bitLen >>> 24`, NOT 0.

Workflow D's Verify Hash now uses the correct implementation. T25 succeeded with this fix. Memory `n8n-crypto-require-blocked` already covers the why-pure-JS context; consider adding a memory specifically for the `>>>` modulo-32 trap.

### 3. Postiz API base path + auth header

Postiz public API lives at `/api/public/v1/`, NOT `/api/`. Authorization header takes the raw key (NO `Bearer ` prefix). Both gotchas were caught during T25 and recorded as memory `postiz-public-api-conventions`. Any future caller into Postiz (Phase 4 outcome logger, future n8n workflows) MUST follow these conventions.

The n8n credential `postiz-api-key` (id `pZtZApIkEy00000A`) was originally seeded with `Bearer <key>`; that's been corrected via direct SQLite DB edit (memory: `n8n-credential-direct-db-edit`).

### 4. n8n `continueErrorOutput` routes to main[1], not "error" connection

Discovered during T20. Both Verify Hash and Postiz Create Post's error paths use `main[1]` wiring. Don't refactor to `"error":[[…]]` — that key is ignored by n8n 2.9.4.

### 5. Reddit deferred to Phase 2.1

Reddit's Responsible Builder Policy gate + Devvit platform shift make new OAuth apps impractical. r/PlotLens subreddit exists (Jeremy's a moderator) but no automated posting in Phase 2. Manual Reddit posting via browser remains the path. Comment replies were always manual-only forever per AC-4 anyway.

### 6. X (Twitter) + LinkedIn deferred to Phase 2.1

Both blocked on Developer Account / Marketing Developer Platform approvals (1-2 weeks each). Phase 2 ships when 5 posts hit Bluesky + Mastodon.

### 7. Mastodon required env-var wiring + granular scopes

Postiz's standard mastodon provider uses `MASTODON_CLIENT_ID/SECRET/URL` env vars (wired in commit `5814fa5`). Mastodon app scopes must be granular (`write:statuses`, `write:media`, `profile`), NOT the broad `read write` checkbox. Documented in `docs/runbooks/postiz-channel-onboarding.md`.

### 8. ~~publish_jobs leftover stale rows~~ ✅ ROW 47 ABANDONED commit `f2ae505`

Row 47 (pre-CTE-fix legacy with hash-mismatch from the `>>>` mod-32 bug) is now `status='abandoned'`. Migration `20260521120000_publish_jobs_add_abandoned_status.sql` added `'abandoned'` to the publish_jobs.status CHECK so future operator-driven retirements are also reachable. Row 62 (T25 SUCCESS) remains as the only legitimate Phase 2 production row.

### 9. Phase 1 unmerged + not operationally validated

`outreach/phase0-phase1` branch contains 73 commits — Phase 1 + Phase 2 work mixed. Phase 2 exit criterion 9 says "tag Phase 2 only after Phase 1 is tagged" — which itself requires 10 real items processed end-to-end (Jeremy's actual usage of the system over a week). Not started.

### 10. ~~publish_jobs has no `created_at` column~~ ✅ FIXED commit `3f9c2e2`

Migration `20260521130000_publish_jobs_add_created_at.sql` added `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` with index on `(status, created_at)` and backfilled existing rows from `approvals.approved_at`. The postgres_exporter `ready_oldest_age_seconds` query (commit `385b821`) and `docs/runbooks/postiz-failed-job-recovery.md` (commit `6a0476c`) now read `created_at` directly — no more JOIN.

### 11. ~~Platform dropdown not coupled to destination input in the approval form~~ ✅ FIXED commit `7122e4a`

Replaced the two-field `approved_platform` + `approved_destination` UI with a single unified `<select name="approved_destination">` where each `<option>` is one Postiz integration (`value=<integration id>`, `data-platform=<identifier>`). An inline `onchange` handler updates a hidden `<input name="approved_platform">` to keep the pair mechanically consistent. Single click per approval = no mismatched pairs.

Limitation accepted: cannot broadcast to multiple integrations on the same platform from one approval. The `publish_jobs` schema is one destination per approval anyway, so this is not a regression.

### 12. ~~Schema test harness accepted any non-zero exit as expected-failure~~ ✅ FIXED commit `bb0c684`

`run_expect_fail` in `apps/outreach-schema/db/tests/run_tests.sh` previously treated ANY error (including NOT NULL violations, type mismatches, even typos) as a passing test. B1's NOT NULL constraint on `approved_platform` slipped past CI because the resulting `23502` errors looked indistinguishable from the `P0001` the tests were supposed to check for; the B8 fixup commit (`fcb0496`) was forced by this hole.

Hardened: `run_expect_fail` now takes an expected SQLSTATE as its second argument. `psql` runs with `VERBOSITY=verbose` so error output is `ERROR:  <SQLSTATE>: <message>`, and the harness greps for the specific class. All three trigger-enforcement tests now assert `P0001` (the trigger's RAISE EXCEPTION default).

Sanity-verified locally on LXC 114: dropping `approved_platform` from a test INSERT produces `23502`, which the new harness correctly reports as `FAIL — got an error, but SQLSTATE was not P0001` (and shows actual output). Pre-fix harness would have silently passed it.

## Architecture decisions made (post-spec)

1. **Temporal resource sizing**: spike-measured values used (history 50m/288Mi requests, all others 50m), not the plan's conservative defaults. Per Phase 0 spike doc.
2. **nodeSelector `role: core-app` on all Temporal pods** to avoid landing on k3s-wrk-3 (ephemeral GPU node with broken taint per memory `k3s-wrk-3-taint-drift`).
3. **Postiz memory limit 8Gi** to hold the 28 Temporal workers Postiz's all-in-one image runs internally.
4. **Postiz registration toggle was temporarily flipped on then off** during T14 admin signup (no admin-seed env vars in Postiz). Currently DISABLE_REGISTRATION=true.
5. **Manual Temporal namespace creation**: the chart creates `temporal-system` but not `default`; Postiz connects to `default`. Created via `temporal operator namespace create --namespace default --retention 7d`. NOT in git. If Temporal is rebuilt, recreate (documented in `docs/runbooks/temporal-restart.md`).
6. **Branch pin** (apps/temporal + apps/postiz Application manifests): both reference `outreach/phase0-phase1` directly. Once Phase 1 merges to main, change targetRevision to `main` or `HEAD`.
7. **ApplyOutOfSyncOnly=true** added to both ArgoCD apps to avoid replay churn on every reconciliation.
8. **Dashboard: DB panels deferred to Phase 2.1.** No Postgres Grafana datasource exists yet; the dashboard surfaces k8s health + Loki errors + a markdown panel with the manual psql queries.
9. ~~**Alert rules use metrics that don't yet exist**~~ ✅ FIXED commit `b935933`. `k8s/observability/exporters/postgres-outreach-exporter/` deploys postgres_exporter against LXC 114; six custom-query gauges live in Prometheus: `outreach_publish_jobs_{ready_oldest_age_seconds,ready_count,failed,sent_to_postiz,manual_required,abandoned}`. T27 alerts now wire to real metrics. `OutreachPublishFailureSustained` will fire ~20 min after a row stays in `failed` (currently failed=0 since row 47 was abandoned in `f2ae505`).
10. **CI manifests-lint uses a built-in-kinds filter** because GitHub-hosted runners don't have Traefik / Infisical / Prometheus-Operator CRDs. ArgoCD validates these against the live cluster at sync time.

## Memory entries from this session (saved to `~/.claude/projects/-home-jacorbello-repos-cortech-infra/memory/`)

All Phase 1 memories still apply. Phase 2 + Phase 2.1 added:
- `n8n-crypto-require-blocked` — `require('crypto')` is blocked in n8n 2.9.4 Code nodes; use pure-JS SHA-256.
- `postiz-public-api-conventions` — base path `/api/public/v1/`, raw Authorization key (no Bearer), CreatePostDto shape.
- `n8n-credential-direct-db-edit` — CryptoJS AES (openssl-compatible) for headless credential fixes.
- `postgres-exporter-custom-query-prefix` — `--extend.query-path` metrics emit `{namespace}_{column}` verbatim (no `pg_` prefix); `--disable-default-metrics` doesn't silence all collectors (need `--no-collector.NAME`).
- `js-unsigned-rshift-modulo-32` — JS `>>>` takes shift amount mod 32; `x >>> 56` is `x >>> 24`. Use hardcoded 0s for high bytes in SHA-256 padding.
- `n8n-continueErrorOutput-routes-main1` — error path lives in `main[1]`, not a separate `"error"` connection key.

Still worth saving in future sessions (not done yet):
- "Postiz Mastodon needs env vars + granular scopes" — currently only in the channel-onboarding runbook.
- "Reddit Responsible Builder Policy blocks new OAuth apps as of late 2024" — deferral context.

## Recent commits (last 15 on branch — `git log --oneline main..HEAD | head -15`)

```
7a7fdc3 fix(workflow-c): Slack approval path includes approved_platform='bluesky'
87056b4 feat(workflow-c): Write Approval CTE inserts approved_platform
cea11ca feat(workflow-c,workflow-d): include approved_platform in hash payload
4f1f3e0 feat(workflow-c): render platform dropdown sourced from Postiz integrations
a144ba8 chore(workflows): refresh stale credentials-matrix comment
61f6eec feat(workflow-c): add Fetch Postiz Integrations HTTP node
fe3c90e feat(outreach-schema): add approvals.approved_platform column
6a0476c docs(runbooks): drop approvals JOIN in failed-job-recovery query
385b821 chore(observability): drop approvals JOIN from outreach_publish_jobs query
3f9c2e2 feat(outreach-schema): add publish_jobs.created_at column + backfill
ac30667 plan(outreach): Phase 2.1 schema cleanup — created_at + approved_platform split
6548206 docs(handoff): enrich Slack quick-approve TODO with destination/edit gotchas
3693864 docs(handoff): SHA-256 audit done; CI now has sha256-audit job
55c8858 test(outreach): SHA-256 RFC 6234 audit + CI drift check
d66c432 docs(handoff): row 47 abandoned + new abandoned status migration
```

(90 commits total on the branch — `git log --oneline main..HEAD` for the full list.)

## TODOs for next session

In priority order:

1. **Phase 1 operational validation** — ≥10 real items / ≥1 week; tag Phase 1. (Only step blocking Phase 2 tag.)
2. **Phase 2 T30** once #1 done + ≥5 production posts + 24h ArgoCD stability. Then merge PR #18 and flip ArgoCD `targetRevision` from `outreach/phase0-phase1` to `main`/`HEAD`.
3. **Clean up live Bluesky test post `cmpfkq5x80003j0aulvbz98h4`** from the B7 smoke test. The synthetic post landed in production Bluesky (plotlens.bsky.social brand handle) — delete from Bluesky web UI or via `bsky.app` app password tooling. The corresponding synthetic rows in `outreach_items`/`approvals`/`publish_jobs` are quarantined and don't need DB cleanup, but the live post on the public timeline does.
4. ~~UX enhancement — couple platform dropdown to destination input~~ ✅ DONE commit `7122e4a`. Unified single-dropdown form (option A from review): one `<select>` where each option is a Postiz integration, hidden `approved_platform` field synced via inline onchange. Smoke-rendered locally with 3 mock integrations (mastodon + 2× bluesky); imported and active on LXC 112.
5. ~~Decide whether Slack quick-approve should enqueue publishing~~ ✅ DONE commit `e205db1`. Wired Slack to dispatch (option 1 chosen): Build Slack Approval includes platform in hash; Write Slack Approval (CTE) gained a `pj` CTE gated on `decision='approved' AND length(approved_destination) > 0`; HTTP Confirm Approval ephemeral message has three states (dispatched / triage-only / rejected). Pre-deploy gate (0 ready rows) confirmed.
6. **Reddit / LinkedIn channel onboarding** when their gating clears. **X is deferred indefinitely** (paid plan cost — see "Phase 2.1 follow-ups" above for full diagnosis).

## Access patterns reminder

- LXC 114 Postgres at **192.168.1.83** (NOT .114; memory `lxc-114-postgres-ip-drift`).
- LXC 112 n8n via two-hop: `ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- ...'"`.
- LXC 123 MinIO at 192.168.1.118.
- LXC 100 NGINX proxy: site configs in `/etc/nginx/sites-available/`, certbot for cert renewal.
- Infisical CLI authenticated on workstation as of session.
- ArgoCD: `kubectl get applications -A` from cortech master 192.168.1.52.
- All gotchas from Phase 1's memory entries still apply.

---

This file evolves. Update it as state changes. Safe to delete after Phase 2 tagged.
