# PlotLens Outreach — Session Handoff

**As of:** 2026-05-20, end-of-Phase-2-build (post-push, awaiting PR for CI to fire)
**Branch:** `outreach/phase0-phase1` (still 1 branch, 65+ commits ahead of `main`, pushed to GitHub)
**Phase 1 spec:** `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md`
**Phase 1 plan:** `docs/superpowers/plans/2026-05-19-plotlens-outreach-phase0-and-phase1.md`
**Phase 2 spec:** `docs/superpowers/specs/2026-05-20-plotlens-outreach-phase2-design.md`
**Phase 2 plan:** `docs/superpowers/plans/2026-05-20-plotlens-outreach-phase2.md`
**Living roadmap:** `docs/superpowers/roadmaps/plotlens-outreach.md`

Read this file first on any session resume. Safe to delete once Phase 2 is tagged.

## Where we are right now

**Phase 1:** ALL 34 tasks BUILT. Operational validation (10 real items end-to-end) NOT done. NOT tagged.

**Phase 2:** T1-T29 done. T30 is the exit gate — it can't be tagged until:
1. Phase 1 is tagged first (exit criterion 9).
2. At least 5 production publish_jobs rows succeed (we have 1).
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

## Resume procedure (next steps in order)

Three concrete next moves, in dependency order:

1. **Workflow C `destination_account` CTE fix.** Highest priority — every production approval today lands with `destination_account=''` and Workflow D's Postiz call returns 400 until someone hand-UPDATEs the row. This blocks Phase 1 operational validation (#2) because you can't process 10 items end-to-end with a manual fix in the loop.
   - File: `apps/outreach-workflows/n8n/review.json` → Write Approval node's `pj` CTE
   - Change: `destination_account` column INSERT value from `NULL` to `ins.approved_destination`
   - Test: re-trigger an approval, confirm row 62-style flow works without intervention
   - See "Known issues" #1 for full context

2. **Open a PR from `outreach/phase0-phase1` → `main`.** CI's `manifests-lint` job ONLY triggers on `pull_request` (verified — direct branch push doesn't fire it; the workflow isn't registered in GitHub Actions until at least one PR exists). Opening a PR:
   - Surfaces the 65-commit diff for any final review pass.
   - Triggers `outreach-ci.yml` (schema + audit + manifests-lint).
   - Lets you watch the new lint job run for real. Locally we verified via `kubectl kustomize` on cortech master that `apps/postiz/overlays/production` and `apps/temporal/extras` both render cleanly, and `helm template temporalio/temporal --version 0.74.0 -f apps/temporal/values.yaml` produces 20 docs — so the job's mechanics should work.
   - Standard PR command: `gh pr create --base main --head outreach/phase0-phase1 --title "Outreach Phase 1+2: approval gate + Postiz/Temporal in production" --body-file <DESCRIPTION>`. Mark as draft until Phase 1 validation completes.

3. **Phase 1 operational validation.** Use the system for ≥1 week, process ≥10 real outreach items end-to-end. Once done, tag Phase 1: `git tag -a outreach-phase1-shipped -m "Phase 1: approval gate end-to-end"`. This unblocks T30.

4. **Phase 2 T30 (tag).** After step 3 completes AND there are ≥5 production posts in `sent_to_postiz` AND the ArgoCD `temporal` + `postiz` Applications stay Synced/Healthy for a full 24h window:
   ```bash
   ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
   psql "$ADMIN_URL" -c "SELECT COUNT(*) FROM publish_jobs WHERE status='sent_to_postiz';"
   ssh root@192.168.1.52 "kubectl get applications -n argocd temporal postiz"
   ```
   Then `git tag -a outreach-phase2-shipped -m "Phase 2: Postiz + Temporal + Workflow D"`.

5. **Phase 2.1 follow-ups (deferred items, see roadmap).** None are urgent; act when traffic warrants:
   - **Reddit Devvit revisit** if Reddit relaxes the Responsible Builder Policy.
   - **X / LinkedIn** when developer-account approvals come through.
   - **n8n pure-JS SHA-256 retroactive audit** against RFC 6234 test vectors.
   - **postgres_exporter custom queries** for `outreach_publish_jobs_ready_oldest_age_seconds` and `_failed_total` so the placeholder alerts in T27 actually fire (currently the metrics don't exist, so the alerts will never trigger — they're harmless but inert until then).

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

### 1. publish_jobs.destination_account is empty after Workflow C writes it

Workflow C's CTE (T18 implementation) sets `destination_account = NULL` in the `pj` CTE, later coerced to `''`. Workflow D's Postiz HTTP node reads `$json.destination_account` for `integration.id`. Empty → Postiz returns 400.

**Workaround during T25:** manually UPDATE the row's `destination_account` to the Postiz integration ID after Workflow C writes it. This worked once for the test — every future production approval will hit the same issue.

**Phase 2.1 fix:** modify Workflow C's CTE to set `destination_account = ins.approved_destination`. The approval form already collects this value (the operator types/pastes the Postiz integration ID into "approved_destination").

Better Phase 2.1 design: separate fields. Have the form ask for "approved_platform" (human-readable: `bluesky`) AND "approved_destination" (Postiz integration ID). Phase 2 collapsed both into `approved_destination` for expediency.

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

### 8. publish_jobs leftover stale rows

Currently row 47 = `failed` (T18 smoke), row 62 = `sent_to_postiz` (T25 SUCCESS). Worth a periodic cleanup query for stale Phase 2 testing detritus before considering T30.

### 9. Phase 1 unmerged + not operationally validated

`outreach/phase0-phase1` branch contains 65+ commits — Phase 1 + Phase 2 work mixed. Phase 2 exit criterion 9 says "tag Phase 2 only after Phase 1 is tagged" — which itself requires 10 real items processed end-to-end (Jeremy's actual usage of the system over a week). Not started.

## Architecture decisions made (post-spec)

1. **Temporal resource sizing**: spike-measured values used (history 50m/288Mi requests, all others 50m), not the plan's conservative defaults. Per Phase 0 spike doc.
2. **nodeSelector `role: core-app` on all Temporal pods** to avoid landing on k3s-wrk-3 (ephemeral GPU node with broken taint per memory `k3s-wrk-3-taint-drift`).
3. **Postiz memory limit 8Gi** to hold the 28 Temporal workers Postiz's all-in-one image runs internally.
4. **Postiz registration toggle was temporarily flipped on then off** during T14 admin signup (no admin-seed env vars in Postiz). Currently DISABLE_REGISTRATION=true.
5. **Manual Temporal namespace creation**: the chart creates `temporal-system` but not `default`; Postiz connects to `default`. Created via `temporal operator namespace create --namespace default --retention 7d`. NOT in git. If Temporal is rebuilt, recreate (documented in `docs/runbooks/temporal-restart.md`).
6. **Branch pin** (apps/temporal + apps/postiz Application manifests): both reference `outreach/phase0-phase1` directly. Once Phase 1 merges to main, change targetRevision to `main` or `HEAD`.
7. **ApplyOutOfSyncOnly=true** added to both ArgoCD apps to avoid replay churn on every reconciliation.
8. **Dashboard: DB panels deferred to Phase 2.1.** No Postgres Grafana datasource exists yet; the dashboard surfaces k8s health + Loki errors + a markdown panel with the manual psql queries.
9. **Alert rules use metrics that don't yet exist** (`outreach_publish_jobs_ready_oldest_age_seconds`, `outreach_publish_jobs_failed_total`). These are placeholders — they'll fire once postgres_exporter is pointed at LXC 114 with custom queries, but won't error in the meantime.
10. **CI manifests-lint uses a built-in-kinds filter** because GitHub-hosted runners don't have Traefik / Infisical / Prometheus-Operator CRDs. ArgoCD validates these against the live cluster at sync time.

## Memory entries from this session (saved to `~/.claude/projects/-home-jacorbello-repos-cortech-infra/memory/`)

All Phase 1 memories still apply. Phase 2 added:
- `n8n-crypto-require-blocked` — `require('crypto')` is blocked in n8n 2.9.4 Code nodes; use pure-JS SHA-256.
- `postiz-public-api-conventions` — base path `/api/public/v1/`, raw Authorization key (no Bearer), CreatePostDto shape.
- `n8n-credential-direct-db-edit` — CryptoJS AES (openssl-compatible) for headless credential fixes.

Worth considering for next session:
- "JavaScript `>>>` is modulo-32 on the shift amount" — caught us in the SHA-256 padding loop; would have silently broken every Workflow D dispatch.
- "n8n continueErrorOutput routes to main[1], not the `error` connection key."
- "Postiz Mastodon needs env vars + granular scopes" — currently in the runbook only.
- "Reddit Responsible Builder Policy blocks new OAuth apps as of late 2024" — deferral context.

## Recent commits (last 10 on branch — `git log --oneline main..HEAD | head -10`)

```
5527d49 feat(plotlens-marketing): Phase 2 observability + runbooks + CI manifests-lint
56412ff fix(workflow-d): Postiz API payload shape — integration per-post + required top-level fields
c4bb719 fix(workflow-d): correct SHA-256 padding
accbd40 docs(roadmap): defer Reddit + capture Phase 2.1 follow-ups
5814fa5 feat(postiz): wire MASTODON_CLIENT_ID/SECRET/URL env vars for OAuth
b4997dd test(workflow-d): add retry-cap and manual_required branch tests
e8804e0 fix(workflow-d): wire Verify Hash error output to Mark Failed Hash
f29e75d feat(outreach-workflows): add Workflow D dispatcher and extend Workflow C CTE
5fe5339 feat(outreach-workflows): authorize publish-dispatcher to use postiz-api-key
04cdd11 fix(postiz): re-lock registration after T14 admin signup
```

(65+ commits total on the branch — `git log --oneline main..HEAD` for the full list.)

## TODOs for next session

In priority order (matches "Resume procedure" above):

1. **Workflow C `destination_account` CTE fix** — blocking #2; ~10 minute fix in `apps/outreach-workflows/n8n/review.json`.
2. **Open a PR** `outreach/phase0-phase1` → `main` (draft) so `manifests-lint` CI fires.
3. **Phase 1 operational validation** — ≥10 real items / ≥1 week; tag Phase 1.
4. **Phase 2 T30** once #3 done + ≥5 production posts + 24h ArgoCD stability.
5. **n8n pure-JS SHA-256 retroactive audit** against RFC 6234 test vectors.
6. **Reddit / X / LinkedIn channel onboarding** when their gating clears.
7. **postgres_exporter custom queries** so the T27 placeholder alerts actually fire.
8. **Memory entries** for `>>>` modulo-32 and `continueErrorOutput` (low priority but useful).

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
