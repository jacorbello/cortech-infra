# Postiz-State Poll Workflow — Design Spec

**Date:** 2026-05-22
**Author:** session brainstorm
**Status:** approved
**Branch:** to land on `outreach/phase0-phase1` (stacked on PR #18)

## Problem

`publish_jobs.status='sent_to_postiz'` and `outreach_items.status='published'` are currently both written on Postiz HTTP 200 by Workflow D (`apps/outreach-workflows/n8n/publish-dispatcher.json`). Postiz publishes to Bluesky/Mastodon via Temporal asynchronously, and that workflow can silently fail.

The canonical proof is `publish_jobs.id=72` (2026-05-22): Postiz returned 200, our DB claimed `published`, Postiz internal `Post.state` flipped `QUEUE → ERROR` because Bluesky's `app.bsky.feed.post` API rejected the 542-grapheme draft text ("grapheme too big (maximum 300, got 542)"). The DB lied for ~30 minutes before the user noticed via the Postiz UI.

Effects:
- Every "production post" count toward Phase 2 T30's "≥5 in `sent_to_postiz`" gate is unreliable.
- Operators get no signal when an async Postiz/Bluesky failure happens.
- `outreach_items.status='published'` cannot be trusted; downstream consumers (Grafana, future analytics) inherit the dishonesty.

## Goal

A new n8n workflow `outreach-publish-poll` becomes the single writer of:
- `publish_jobs.status='published'`
- `publish_jobs.published_at`, `publish_jobs.published_url`
- `outreach_items.status='published'`

Workflow D drops its premature `outreach_items.status='published'` write. The DB reflects reality at most ~2 minutes behind Postiz.

## Architecture

```
LXC 112 n8n
├── outreach-publish-dispatcher (Workflow D, existing)
│     Schedule 2 min → Fetch ready publish_jobs → Verify Hash →
│     Postiz POST /posts → Mark Sent (status=sent_to_postiz, sent_at, postiz_post_id)
│     [DELETED: Rollup outreach_items.status='published']
│
└── outreach-publish-poll (NEW, this spec)
      Schedule 2 min → Fetch sent_to_postiz rows →
      Postiz GET /posts?startDate=&endDate= (one call per cycle) →
      Reconcile (PUBLISHED | ERROR | QUEUE-fresh | QUEUE-stuck | not-found | unknown) →
      Switch by action →
        ├── Mark Published (CTE: publish_jobs + outreach_items atomic)
        ├── Mark Failed   (Postiz state=ERROR)
        ├── Mark Failed Orphan (Postiz post deleted)
        ├── Mark Manual   (stuck QUEUE >30 min)
        └── Slack Warning (unknown Postiz state)
```

## State machine

The poll's complete transition table. Source state is always `publish_jobs.status='sent_to_postiz' AND published_at IS NULL`.

| Postiz lookup result | publish_jobs.status | outreach_items.status | Side effects |
|---|---|---|---|
| found, `state=PUBLISHED` | `published` (+ `published_at` from Postiz `publishDate`, `published_url` from `releaseURL`) | `published` (only if currently `reviewed`) | outcomes `kind=publish_confirmed` |
| found, `state=ERROR` | `failed` (+ `failure_reason='Postiz state=ERROR'`) | unchanged | outcomes `kind=publish_failed` + Slack alert |
| found, `state=QUEUE`, age `< 30m` | unchanged | unchanged | none (no-op) |
| found, `state=QUEUE`, age `≥ 30m` | `manual_post_required` (+ `failure_reason='Stuck in Postiz QUEUE >30m'`) | unchanged | outcomes `kind=publish_stuck` + Slack alert |
| not found in list (deleted via UI or by us) | `failed` (+ `failure_reason='Postiz post not found'`) | unchanged | outcomes `kind=publish_orphaned` + Slack alert |
| found, `state` not in {PUBLISHED, ERROR, QUEUE} (defensive) | unchanged | unchanged | Slack warning ("Unknown Postiz state: `<state>`") |

Invariants:
- `published` is terminal on both tables. The poll never demotes.
- The poll only flips `outreach_items` to `published` if it is currently `reviewed`. A `rejected` or `archived` item is never promoted.
- All writes are idempotent: the `published_at IS NULL` guard in the SQL means re-running the poll on the same row is a no-op.

## Cadence

Schedule trigger every **2 minutes** (matches the dispatcher). Worst-case latency from Postiz state change to DB reconciliation: ~2 minutes. Acceptable for a Slack-alert escalation path.

## Workflow shape (n8n nodes)

```
Schedule Trigger (every 2 min)
  ↓
Fetch Pending [Postgres, runOnceForAllItems]
  SELECT pj.id AS publish_job_id,
         pj.postiz_post_id,
         pj.sent_at,
         EXTRACT(EPOCH FROM (now() - pj.sent_at)) AS age_seconds,
         (SELECT d.outreach_item_id
            FROM approvals a JOIN drafts d ON d.id = a.draft_id
            WHERE a.id = pj.approval_id) AS outreach_item_id
    FROM publish_jobs pj
   WHERE pj.status = 'sent_to_postiz'
     AND pj.published_at IS NULL
   ORDER BY pj.sent_at NULLS FIRST, pj.id;
  ↓
IF: rows present?  → No → Respond OK / end
  ↓ Yes
Compute Window Bounds [Code, runOnceForAllItems]
  // startDate = min(sent_at) − 5 min (clock-drift slack)
  // endDate   = now() + 5 min
  // emits ONE item carrying { startDate, endDate, rows: [...] }
  ↓
Postiz List Posts [HTTP, GET /api/public/v1/posts?startDate=&endDate=]
  authentication: postiz-api-key (raw key, no Bearer)
  onError: continueErrorOutput → Slack Alert (HTTP-layer failure) → end
  ↓
Reconcile [Code, runOnceForAllItems]
  // Build map: postiz_id → { state, publishDate, releaseURL }
  // For each row from Fetch Pending → emit
  //   { publish_job_id, outreach_item_id, postiz_post_id, action, payload }
  // action ∈ { PUBLISH, FAIL_ERROR, FAIL_ORPHAN, STUCK, NOOP, WARN_UNKNOWN }
  ↓
Switch by action
  ├── PUBLISH        → Mark Published      [Postgres CTE] → Log Outcome (publish_confirmed)
  ├── FAIL_ERROR     → Mark Failed         [Postgres]     → Log Outcome (publish_failed)   → Slack Alert
  ├── FAIL_ORPHAN    → Mark Failed Orphan  [Postgres]     → Log Outcome (publish_orphaned) → Slack Alert
  ├── STUCK          → Mark Manual         [Postgres]     → Log Outcome (publish_stuck)    → Slack Alert
  ├── WARN_UNKNOWN   → Slack Warning (no DB write)
  └── NOOP           → end
```

Design notes:
- One Postiz API call per cycle (list query bounded by `min(sent_at)`). Scales linearly with concurrent in-flight jobs.
- `Reconcile` is `runOnceForAllItems` mode and returns an array — no `runOnceForEachItem` return-shape trap (cf. Followup 11 `code-node-return-shape-audit.js`).
- All Postgres mutations are CTE-atomic where they touch both `publish_jobs` and `outreach_items`.

## Mark Published CTE

```sql
WITH pj_update AS (
  UPDATE publish_jobs
     SET status = 'published',
         published_at = $1,           -- Postiz publishDate
         published_url = $2           -- Postiz releaseURL
   WHERE id = $3
     AND status = 'sent_to_postiz'
     AND published_at IS NULL
  RETURNING (SELECT d.outreach_item_id
               FROM approvals a JOIN drafts d ON d.id = a.draft_id
              WHERE a.id = approval_id) AS outreach_item_id
)
UPDATE outreach_items
   SET status = 'published'
 WHERE id = (SELECT outreach_item_id FROM pj_update)
   AND status = 'reviewed';
```

Idempotent (guard on `sent_to_postiz` + `NULL published_at`). Safe against double-execution. Will not promote `outreach_items` from any state other than `reviewed`.

## Workflow D modifications

File: `apps/outreach-workflows/n8n/publish-dispatcher.json`.

Two surgical edits:

1. **Delete** the `Rollup outreach_items` Postgres node entirely. Its UPDATE wrote `outreach_items.status='published'` prematurely on Postiz HTTP 200.
2. **Remove** the connection edges from `Mark Sent`, `Mark Failed`, and `Mark Manual` into `Rollup outreach_items`. These three nodes become terminal in the dispatcher.

`Mark Sent` is unchanged: it continues writing `publish_jobs.status='sent_to_postiz'`, `sent_at=now()`, `postiz_post_id=<Postiz id>`. That remains factually accurate ("we handed it to Postiz").

`Mark Manual` is unchanged: `publish_jobs.status='manual_post_required'`. The semantics "this needed human intervention" stay in `publish_jobs`; `outreach_items` is no longer touched by Workflow D.

Net delta: one node deleted, three connection edges removed.

## Observability

### `outcomes` table — new audit `kind` values (JSON-in-notes pattern)

The `outcomes` table schema has columns `id, publish_job_id (nullable), impressions, replies, clicks, signups, notes (text), captured_at`. It has **no `kind` column** — the existing `Log Notification` audit pattern in review.json stuffs `{kind, outreach_item_id, ...}` into `notes::jsonb` and queries via `notes::jsonb->>'kind' = '<value>'`. The poll's audit writes follow the same pattern.

Each new audit row is `INSERT INTO outcomes (publish_job_id, notes) VALUES ($1, $2)` where `$2` is a `jsonb_build_object(...)::text` value:

| `notes::jsonb->>'kind'` | other JSON fields |
|---|---|
| `publish_confirmed` | `outreach_item_id`, `postiz_post_id`, `published_at`, `published_url` |
| `publish_failed` | `outreach_item_id`, `postiz_post_id`, `reason` (`'postiz_error'` or `'postiz_orphan'`) |
| `publish_stuck` | `outreach_item_id`, `postiz_post_id`, `age_seconds` |

Idempotence: the upstream guard on `Mark Published CTE` (`status='sent_to_postiz' AND published_at IS NULL`) and the equivalents on the failed/stuck paths prevent double-execution from writing duplicate outcomes rows. Even if it did, downstream consumers (dedup queries) can `DISTINCT ON (publish_job_id, notes::jsonb->>'kind')` if ever needed.

`outcomes.publish_job_id` is `NULLABLE` since the `20260519120600` migration — but for this workflow we always have a `publish_job_id`, so we always set it.

### Slack alerts

Posted to the existing `SLACK_OUTREACH_CHANNEL_ID`, prefixed `:rotating_light: outreach-poll`. Message bodies include `publish_job_id`, `outreach_item_id`, `postiz_post_id`. Type-specific extras:

- **`publish_failed`** — first 200 chars of `final_text` (joined from the publish_jobs → approvals → drafts chain). Operator can see what was attempted.
- **`publish_stuck`** — age in human-readable form ("stuck for 32 min").
- **`publish_orphaned`** — "Postiz post not found — likely deleted via UI."
- **`WARN_UNKNOWN`** — "Unknown Postiz state: `<state>`. Add handling to the poll."

No `@here`/`@channel` mentions in v1. Operator monitors the channel actively.

### Prometheus / Grafana

No new metrics in v1. Existing gauges (`outreach_publish_jobs_failed`, `outreach_publish_jobs_manual_required`, `outreach_publish_jobs_sent_to_postiz`) reflect the poll's writes automatically. Existing dashboard panels start showing reality without edits.

The `outreach_publish_jobs_sent_to_postiz` alert threshold (if any) must be ≥30 min to absorb steady-state poll lag. Verify and adjust during plan execution.

## Schema migrations

**None.** The required statuses (`published` on `publish_jobs` and `outreach_items`) and columns (`published_at`, `published_url`, `failure_reason`, `postiz_post_id`, `sent_at`) already exist.

## Testing

### Schema tests (`apps/outreach-schema/db/tests/`)

1. **Mark Published idempotence.** Insert a `publish_jobs` row with `status='sent_to_postiz', published_at=NULL`. Execute the Mark Published CTE twice with the same inputs. Assert only the first call mutates rows; second is a no-op. Assert the linked `outreach_items` row's `status` is `published` exactly once.
2. **Mark Published does not demote.** Insert a `publish_jobs` row pointing at an `outreach_items` row currently `status='rejected'`. Execute the CTE. Assert `outreach_items.status` is unchanged.

### CI drift guards (`apps/outreach-workflows/tests/sha256-audit/`)

Wired into `outreach-ci.yml` `sha256-audit` job:

1. **`poll-workflow-status-writes-audit.js`** — iterates every n8n workflow's Postgres-node SQL. Fails if any workflow other than `outreach-publish-poll.json` contains a write of `outreach_items.status='published'`. Catches accidental re-introduction of Workflow D's old Rollup.
2. **`postiz-list-window-audit.js`** — pins that the poll's Postiz GET URL includes both `startDate=` and `endDate=` query params. Bare `/posts` returns 400 per live probe.
3. **`workflow-d-no-rollup-audit.js`** — pins that `publish-dispatcher.json` contains no node named `Rollup outreach_items` and no Postgres node writes to `outreach_items`. Pairs with #1.

### Sandbox test (`apps/outreach-workflows/tests/sha256-audit/`)

4. **`poll-reconcile-state-machine.js`** — VM-sandbox the `Reconcile` Code node. Six input vectors covering every row of the state machine table (PUBLISHED / ERROR / QUEUE-fresh / QUEUE-stuck / not-found / unknown-state). Assert the emitted `action` matches the expected per row.

## Deploy plan

Subject to user-confirmed n8n restart window (active session boundary: Jeremy is using Phase 1 validation).

1. PR with new workflow JSON + Workflow D edit + 3 audit scripts + 1 sandbox test + 2 schema tests. Push to `outreach/phase0-phase1`. CI green.
2. **Pre-deploy gate.** `SELECT count(*) FROM publish_jobs WHERE status='ready'` returns 0. (Same gating pattern as B4/B7.)
3. `n8n import:workflow` for `outreach-publish-poll.json` and the edited `publish-dispatcher.json`.
4. `n8n update:workflow --id=<poll-id> --active=true`.
5. `systemctl restart n8n.service` on LXC 112.
6. Post-restart: `journalctl -u n8n.service -n 50` confirms `Activated workflow "outreach-publish-poll"`. DB: `SELECT id, name, active FROM workflow_entity WHERE id='pOlLpUbLiShReS01'` returns `active=1`.
7. **Synthetic smoke.** Insert a synthetic `publish_jobs` row with `status='sent_to_postiz', postiz_post_id='cmpel07680002j0au2phuim4q'` (known `state=PUBLISHED` from live probe). Wait one poll cycle (≤2 min). Assert row transitions to `published`, `published_at = 2026-05-20T21:36:16.084Z`, `published_url = https://bsky.app/...`. Delete synthetic row.
8. **Backfill row 62.** The same poll cycle catches row 62 (the legitimate one, also `cmpel07680002j0au2phuim4q`) and flips it to `published`. This becomes the first honest production-post row toward Phase 2 T30's ≥5 gate.

## Rollback

If the poll misbehaves:
- `n8n update:workflow --id=<poll-id> --active=false` deactivates within seconds.
- Workflow D's modified behavior (no premature `outreach_items.published` write) still holds. The DB is honest but `published` transitions stop until the poll is fixed.
- To fully revert: re-import the prior `publish-dispatcher.json` from git, then restart.
- Poll's writes are operator-reversible via psql (`UPDATE publish_jobs SET status='sent_to_postiz', published_at=NULL, published_url=NULL WHERE id=$1`).

## Out of scope (v1)

- **Bluesky-side deletion detection** (`releaseURL` 404 polling). Postiz is our source of truth for whether we published; Bluesky-side deletion after publish is operator territory.
- **Postiz webhook integration.** Polling + webhook hybrid is a future optimization, not v1.
- **Multi-skeet threading reconciliation.** Threading isn't deployed yet (HANDOFF priority 2); add when threading lands.
- **`outreach_publish_jobs_published_total` counter.** Optional follow-up if Grafana wants a publish-rate trend line.
- **Auto-retry on Postiz `ERROR`.** Deterministic failures (text-too-long) don't benefit from retry; transient-failure classification is overkill until we see real transient cases.

## References

- `apps/outreach-workflows/n8n/publish-dispatcher.json` — Workflow D, two-edit target
- `apps/outreach-schema/db/migrations/20260519120300_create_publish_jobs.sql` — base schema
- `apps/outreach-schema/db/migrations/20260520120100_outreach_items_published_status.sql` — added `published` to outreach_items
- `apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js` — Followup 11 CI guard the poll must NOT regress against
- Memory: `postiz-public-api-conventions` (raw Authorization key, no Bearer; `/api/public/v1/` base path)
- Memory: `postiz-err-true-swallows-integration-errors` (Postiz error swallowing pattern — relevant for `WARN_UNKNOWN`)
- Memory: `lxc-114-postgres-ip-drift` (LXC 114 Postgres is at 192.168.1.83, not .114)
- Live probe (2026-05-22): `GET /api/public/v1/posts?startDate=...&endDate=...` returns `{posts: [{id, state, publishDate, releaseURL, integration, ...}]}` with `state ∈ {PUBLISHED, ...}` confirmed via row 62 (`cmpel07680002j0au2phuim4q`)
- Existing audit-log pattern: `apps/outreach-workflows/n8n/review.json` → `Log Notification` node writes `INSERT INTO outcomes (publish_job_id, notes)` with `notes::jsonb` containing `kind` + `outreach_item_id` — the poll's outcomes writes follow this same shape

## Confirmed assumptions (self-review evidence)

These claims load-bear the design; verified inline before spec was approved:

1. **`outreach_items.status='reviewed'` is set on approval.** Both `Write Approval (CTE)` (form path) and `Write Slack Approval (CTE)` (Slack-quick-approve path) in `apps/outreach-workflows/n8n/review.json` write `outreach_items.status='reviewed'`. The Mark Published CTE's `AND status='reviewed'` guard fires correctly on both paths.
2. **No other workflow writes `outreach_items.status='published'`.** Grep across all `apps/outreach-workflows/n8n/*.json`: the only writer is Workflow D's `Rollup outreach_items` (being deleted). After the change, the poll is the unique writer — pinned by `poll-workflow-status-writes-audit.js`.
3. **All Workflow D status-mark nodes route to `Rollup outreach_items`.** `Mark Sent`, `Mark Failed`, and `Mark Manual` all have edges into the Rollup. Deleting the Rollup detaches all three; they become terminal in the dispatcher. (`Mark Failed Hash` was never wired to Rollup — its UPDATE only touches `publish_jobs`.)
