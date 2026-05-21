# PlotLens Outreach — n8n Workflow Reference

These are the 7 active workflows on LXC 112 powering the PlotLens outreach pipeline. Read top-to-bottom for the discovery → draft → review → dispatch → publish flow. Source of truth for every node listed here is the JSON export under `apps/outreach-workflows/n8n/`; do not infer behavior from this guide alone if the JSON disagrees.

```
                                  +------------------+
                                  | outreach-smoke   |  daily 09:00 UTC
                                  | (synthetic POST) |
                                  +--------+---------+
                                           |
              external POST                v
              (manual webhook)     +----------------------+
              ----------------->   |  outreach-discover   |  + RSS pull every 30 min
                                   |  Workflow A          |
                                   +----------+-----------+
                                              |
                                              v
                                      outreach_items (status=discovered)
                                              |
                                              v
                                   +----------------------+
                                   |  outreach-draft      |  schedule every 5 min
                                   |  Workflow B          |  Sonnet (3 variants) + Haiku risk
                                   +----------+-----------+
                                              |
                                              v
                                      drafts (status=needs_human_review, +content_hash)
                                              |
                +-----------------------------+-----------------------------+
                | Slack notify path                                          | Form path
                v                                                            v
        Slack message in #plotlens-outreach                          GET /webhook/render-approval-form
        (Approve/Reject/Open form buttons)                           (HTML form w/ Postiz integration picker)
                |                                                            |
                | Approve  -> POST /webhook/slack-interactive                 |  POST /webhook/submit-approval
                |  (Verify Slack Signature)                                   |  (Build Approval)
                |                                                            |
                +-----------------------------+-----------------------------+
                                              |
                                              v
                                  approvals (decision=approved|rejected|manual_only)
                                  + publish_jobs (status=ready)  -- enforced by
                                    the enforce_approval_match Postgres trigger
                                              |
                                              v
                                   +----------------------+
                                   | outreach-publish-    |  schedule every 2 min
                                   |   dispatcher         |  Workflow D
                                   +----------+-----------+
                                              |
                +-----------------------------+-----------------------------+
                |                             |                             |
                v                             v                             v
         Verify Hash FAIL              Postiz Create Post            publish_mode=manual_required
         -> publish_jobs.status        -> publish_jobs.status        -> publish_jobs.status
            = failed (hash)               = sent_to_postiz              = manual_post_required
                                          + outreach_items.published    (Workflow E DMs operator)
                                              ^
                                              |
                              +-----------------------+
                              | outreach-manual-      |  schedule every 2 min
                              |   publish             |  Workflow E
                              +-----------------------+
                                   Slack DM to operator with
                                   approved text to paste

                              +-----------------------+
                              | outreach-expire-stale |  daily 03:00 UTC
                              | (drafts >14d, approvals expires_at < now())
                              +-----------------------+
```

## Live state — workflow inventory

| Workflow ID | Name | Trigger | Phase |
|---|---|---|---|
| `dScvr0utReAcHW01` | outreach-discover | Webhook `POST /webhook/outreach-discover` + RSS schedule every 30 min | 1 |
| `dRaFtWfOutreach001` | outreach-draft | Schedule every 5 min | 1 |
| `rEv1eWoUtReAcH001` | outreach-review-notify | Schedule every 2 min + 3 webhooks (`render-approval-form`, `submit-approval`, `slack-interactive`) | 1 + 2 |
| `eXp1rEsTaLeWf001` | outreach-expire-stale | Schedule daily 03:00 UTC | 1 |
| `mAnUaLpUbLiSh0001` | outreach-manual-publish | Schedule every 2 min | 1 |
| `sMoKeOutreachW001` | outreach-smoke | Schedule daily 09:00 UTC | 1 |
| `pUbLiShDiSpAtCh01` | outreach-publish-dispatcher | Schedule every 2 min | 2 |

All seven are `active: true` on LXC 112. The systemd drop-in `/etc/systemd/system/n8n.service.d/slack-env.conf` provides `SLACK_SIGNING_SECRET`, `SLACK_OUTREACH_CHANNEL_ID`, `SLACK_OUTREACH_OPERATOR_USER_ID`, `POSTIZ_API_KEY`, `POSTIZ_API_BASE_URL`, and `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`. Without that drop-in nothing using `$env` works.

## Common machinery

**Pure-JS SHA-256.** `require('crypto')` is blocked in the n8n 2.9.4 task runner (see memory `n8n-crypto-require-blocked`), so a hand-rolled SHA-256 is embedded inline in five Code nodes:

- `draft.json` → `Apply Risk Score` (computes per-draft `content_hash` on insert)
- `review.json` → `Build Approval` (form path), `Build Slack Approval` (Slack path), `Verify Slack Signature` (HMAC over the raw `payload=…` body)
- `publish-dispatcher.json` → `Verify Hash`

`apps/outreach-workflows/tests/sha256-audit/audit.js` runs in the `sha256-audit` CI job. It extracts all five copies, asserts they are bit-for-bit identical (single md5), then evaluates the canonical body against RFC 6234 Appendix B vectors, padding-boundary lengths, multibyte UTF-8, and a realistic outreach payload. If you edit one copy, you must edit all five and the audit must stay green. The bug being defended against is `js-unsigned-rshift-modulo-32` (`x >>> 56` evaluates to `x >>> 24`, not 0); padding now uses hardcoded high-byte zeros.

**Hash payload shape (Phase 2.1, 6-field).** The content hash committed into `drafts.content_hash` is `sha256(draft_text + recommended_destination + suggested_post_type)` — set at draft time before destination/platform are picked. At approval time, the approval re-hashes with the four user-selected fields: `sha256(finalText + approved_destination + approved_post_type + approved_platform)` and writes that to `approvals.approved_content_hash` and (after the CTE pj insert) to `publish_jobs.payload_hash`. Workflow D recomputes the same 4-field hash and refuses to publish on mismatch. Phase 2.1 (commit `cea11ca`) added `approved_platform` to make the hash bind the platform identity, not just the integration ID — hence "6 fields" in the spec language (3 fields baked into the draft at draft time, then 4 fields re-bound at approval time including `approved_platform`).

**Slack signing-secret verification.** Lives in `review.json` → `Verify Slack Signature`. Reconstructs `v0:<ts>:payload=<urlencoded>` and HMAC-SHA-256s it with `$env.SLACK_SIGNING_SECRET`. Rejects requests with a timestamp drift >300s (replay window) or a missing/mismatched `X-Slack-Signature` header. The HMAC implementation is `hmacSha256(...)` defined inline above the verify block; it reuses the same sha256 primitive but operates on raw byte arrays (`sha256Raw`) to avoid double UTF-8 encoding the key.

**`enforce_approval_match` Postgres trigger.** Lives in the outreach DB (LXC 114). When `publish_jobs` is inserted, the trigger enforces that the row's `destination_platform`, `destination_account`, and `payload_hash` match the linked `approvals` row's `approved_platform`, `approved_destination`, and `approved_content_hash`. Both Workflow C (`Write Approval (CTE)`) and Workflow D rely on this — Workflow C's `pj` CTE inserts the publish_job populated directly from `ins.*` columns in the same statement, so the trigger always sees a consistent pair. Workflow D never touches the platform/destination/hash fields, so the trigger stays satisfied for the lifetime of the job. Trigger violations raise `SQLSTATE P0001`; the schema test harness asserts on that specific class (see memory in HANDOFF known-issue #12).

---

## outreach-discover (`dScvr0utReAcHW01`)

**File:** `apps/outreach-workflows/n8n/discover.json`
**Trigger:** `POST /webhook/outreach-discover` (header-auth) + `Schedule Trigger` every 30 min for RSS
**Phase:** 1
**One-line:** Two entry paths (manual webhook, scheduled RSS pull) that normalize a source URL into a row in `outreach_items` with status `discovered`.

### Pipeline position

The pipeline's only ingestion point. Manual entries hit the webhook (used by `outreach-smoke` and by Jeremy via curl/bookmarklet). The schedule branch pulls five hardcoded craft-of-writing RSS feeds every 30 min. Both branches write to `outreach_items` with `ON CONFLICT (source_platform, source_url) DO NOTHING`. Downstream consumer is `outreach-draft`, which polls `status='discovered'` rows.

### Key nodes

- `Webhook` — `POST /outreach-discover`, header-auth via `discover-webhook-secret` credential. Body shape: `{url: "...", notes: "..."}`.
- `Normalize Input` — Code node. Validates URL matches `^https?://`, normalizes into `{source_platform: 'manual', source_url, source_excerpt: notes, source_author: null}`. Throws on bad URL → webhook 5xxs.
- `Insert Outreach Item` — Postgres. `INSERT ... ON CONFLICT (source_platform, source_url) DO NOTHING RETURNING id`. Idempotent.
- `Respond to Webhook` — Returns `{accepted: true, id: <newId>}` (id is undefined when conflict skipped — caller must not assume id is present).
- `Schedule Trigger` (RSS branch) — every 30 min, no specific time pinning.
- `RSS Feed List` — hardcoded list: Creative Penn, Writers Helping Writers, Jane Friedman, Helping Writers Become Authors, Reedsy. Edit this node to add/remove feeds.
- `Split In Batches` (size 1) → `RSS Read` → `Normalize RSS` → `Insert RSS Item`. The Split In Batches uses output index 1 for the loop body (memory `n8n-split-in-batches-output-order`).

### Integrations / credentials

- `discover-webhook-secret` (httpHeaderAuth, `R8FUCCmGLkzJdEPB`)
- `outreach-db-n8n` (postgres, `fOZmso5kyXr6Agdn`)

### DB touched

- Writes: `outreach_items` (INSERT, idempotent via `ON CONFLICT (source_platform, source_url)`)
- Reads: none

### Failure modes / gotchas

- Webhook caller must include the auth header set in Infisical `DISCOVER_WEBHOOK_SECRET`. Missing header → 401, the smoke workflow will alert.
- `ON CONFLICT DO NOTHING` means re-POSTing the same URL is a no-op — the webhook responds with `{accepted: true, id: undefined}`. Treat any `accepted: true` as success.
- The RSS feed list is in-code; no DB-backed config. Restart n8n is not needed to change (workflow JSON update + `n8n import:workflow` + reload).
- The webhook path is not rate-limited at the n8n layer. If an attacker has the shared secret, they can spam `outreach_items` rows — they'd all land with `source_platform='manual'` and be visible in the DB as junk URLs. Rotate the secret in Infisical + Slack the n8n credential edit if this ever happens.

---

## outreach-draft (`dRaFtWfOutreach001`)

**File:** `apps/outreach-workflows/n8n/draft.json`
**Trigger:** `Schedule Trigger` every 5 min
**Phase:** 1
**One-line:** Pulls up to 10 `discovered` items off the queue, asks Anthropic Sonnet for three voiced variants, asks Haiku for per-variant risk scores, hashes each, and writes them as three rows in `drafts` (`status=needs_human_review`).

### Pipeline position

The only writer to `drafts`. Reads `outreach_items` (claims via `FOR UPDATE SKIP LOCKED` so multiple ticks won't double-claim). Output is three draft rows per item with stable `content_hash` values that `outreach-review-notify`'s form path and `outreach-publish-dispatcher`'s verify path both bind against (post Phase 2.1, the draft-time hash uses 3 fields; the approval re-hashes with 4 including the user's platform pick — see "Common machinery").

### Key nodes

- `Fetch Candidates` — Postgres. Atomic claim: `UPDATE outreach_items SET status='drafting' WHERE id IN (SELECT id FROM outreach_items WHERE status='discovered' ORDER BY discovered_at LIMIT 10 FOR UPDATE SKIP LOCKED) RETURNING ...`. Drop the LIMIT here to fan out wider; the rest of the workflow is per-item.
- `Filter Candidates` — Code. Drops the n8n Postgres "no rows → `{success: true}`" sentinel row that would otherwise pollute downstream items.
- `Build Prompt` — Code. Renders the long Sonnet prompt (voice rules, channel rules, JSON output schema). Asks for 3 variants: `helpful_only`, `founder_context`, `soft_product`.
- `Call Anthropic` — LangChain Anthropic node, model `claude-sonnet-4-6`, simplify off, system="You output only valid JSON". Note this node iterates only `item[0]` per memory `n8n-langchain-anthropic-item0` — that's why the workflow runs one outreach_item at a time despite Fetch Candidates returning up to 10.
- `Validate Response` — Code. Pulls `content[0].text`, strips ``` fences if present, asserts `drafts` is length 3 and each has variant + draft_text. Throws on parse failure (kills the per-item branch).
- `Fan Out Variants` → `Build Risk Prompt` — Combines all 3 variants into a single Haiku prompt to dodge the item[0] iteration limit.
- `Call Haiku` — LangChain Anthropic, `claude-haiku-4-5-20251001`, max 600 tokens. Returns one JSON array with 3 risk_score entries.
- `Apply Risk Score` — Code. **Embeds the canonical pure-JS SHA-256.** Maps Haiku scores onto variants by `variant` key (defaults to risk=75 on parse failure or missing entry), computes `content_hash = sha256(draft_text + recommended_destination + suggested_post_type)`, returns all 3 rows in a single `{rows: [...]}` item.
- `Insert Draft` — Postgres. One INSERT with 27 positional params writing all 3 variants in one statement, columns: `outreach_item_id, variant, model_provider, model_name, prompt_version, draft_text, suggested_destination, suggested_post_type, risk_flags::jsonb, risk_score, manual_only, content_hash`.
- `Mark Drafted` — Postgres. `UPDATE outreach_items SET status='drafted'`.

### Integrations / credentials

- `outreach-db-n8n` (postgres)
- `anthropic-api-key` (anthropicApi, `KHgVcFOKeWW5rMme`)

### DB touched

- Writes: `outreach_items` (UPDATE status: `discovered → drafting → drafted`), `drafts` (INSERT three rows per outreach_item)
- Reads: `outreach_items`

### Failure modes / gotchas

- Anthropic 5xx / token timeout will throw in `Call Anthropic` and `Validate Response` — the outreach_item stays at `status='drafting'` (NOT rolled back to `discovered`). If the queue stalls, look for items stuck in `drafting` and decide whether to reset them.
- Haiku JSON parse failures silently fall back to `risk_score=75` per variant. If you see every draft scored exactly 75 in the DB, Haiku is returning malformed JSON.
- The 3-positional INSERT requires exactly 3 rows. If `Validate Response` ever lets fewer through, this will throw with a positional-param error. The validator's length-3 assertion is load-bearing.
- The draft-time `content_hash` is calculated against the variant's *suggested* destination/post-type, not the human-approved one. The approval flow re-hashes with the final selection — do not assume `drafts.content_hash` matches `approvals.approved_content_hash`.

---

## outreach-review-notify (`rEv1eWoUtReAcH001`)

**File:** `apps/outreach-workflows/n8n/review.json`
**Trigger:** `Schedule Trigger` every 2 min + 3 webhooks (`GET /webhook/render-approval-form`, `POST /webhook/submit-approval`, `POST /webhook/slack-interactive`)
**Phase:** 1 + 2 (CTE extended in T18 to also insert `publish_jobs`)
**One-line:** Slack-notifies the operator about pending drafts, serves the HTML approval form, persists approvals (form + Slack-button paths) atomically alongside their `publish_jobs` row.

### Pipeline position

Sits between drafting and dispatch. Reads `drafts` and `outreach_items`; writes `approvals` and (when decision is `approved`/`manual_only`) `publish_jobs` in a single CTE so the `enforce_approval_match` trigger sees a self-consistent insert. Downstream of the form/Slack write, `outreach-publish-dispatcher` (for `postiz_scheduled`/`postiz_immediate`) and `outreach-manual-publish` (for `manual_only`) pick up the work.

### Sub-flow 1: Schedule → Slack notification

- `Find Items` — Postgres. Returns up to 5 outreach_items in `drafted` whose `helpful_only` draft is in `needs_human_review` and that have no prior `notified` outcome row.
- `Split In Batches` — size 1; output index 1 carries the loop body.
- `Build Slack Blocks` — Code. Builds Block Kit blocks: section with item id / platform / risk badge + source link, then an `actions` row. **If `risk < 20`, prepends an `Approve helpful-only as-drafted` primary button** (this is the quick-approve path). Otherwise only Reject + Open-form are offered.
- `Slack Notify` — Slack node, channel id hardcoded to `C0B4SUTP8R4` because `$env` doesn't work inside the channelId field selector in n8n 2.9.4. Edit `channelId.value` to switch channels.
- `Log Notification` — Postgres. Inserts a `notified` row into `outcomes` so the next tick won't re-notify the same item.

### Sub-flow 2: GET /webhook/render-approval-form (form path)

- `Webhook GET Render Form` — basic-auth via `n8n-form-auth`. Query: `?outreach_item_id=<id>`.
- `Validate Query Param` → `Valid ID?` — IF gate; bad ID renders an HTML error.
- `Postgres Load Drafts` — pulls all variants for the item (ordered by variant). Uses a `UNION ALL` against a synthetic NULL row so the response is never empty (rendered HTML then says "No pending drafts").
- `Fetch Postiz Integrations` — HTTP GET `$env.POSTIZ_API_BASE_URL/integrations`, header-auth via `postiz-api-key` (raw key, no Bearer prefix — see memory `postiz-public-api-conventions`).
- `Code Render HTML` — Code (runOnceForAllItems). Renders a single HTML form: one `<textarea>` per variant, a chosen-variant `<select>`, a unified channel `<select name="approved_destination">` where each `<option>` carries `value=<integration id>` and `data-platform=<identifier>`. Inline `onchange` mirrors the data-platform into a hidden `<input name="approved_platform">`. This is the "unified dropdown" — one click sets both destination and platform, no mismatched pairs possible.
- `Respond to Webhook` — text/html.

### Sub-flow 3: POST /webhook/submit-approval (form path)

- `Webhook POST Submit Approval` — basic-auth.
- `Build Approval` — Code. **Embeds pure-JS SHA-256.** Whitelists decision (`approved` / `rejected` / `manual_only` / `save_for_later`), chosen_variant (the 3 known variants), and `approved_platform` (`bluesky`/`mastodon`/`reddit`/`x`/`linkedin`). Reads the textarea for the chosen variant, compares to its hidden `original_text_*` to compute `edited_text` (null if unchanged). Computes `approved_content_hash = sha256(finalText + destination + postType + platform)`.
- `Save For Later?` — IF gate. `save_for_later` → renders an HTML acknowledgement and exits without touching `approvals`.
- `Write Approval (CTE)` — Postgres. Single statement with five CTEs:
  - `ins` — `INSERT INTO approvals (...) RETURNING id, draft_id, decision, approved_destination, approved_content_hash, approved_platform`.
  - `upd1` — sets the chosen draft's status (approved / approved / rejected based on decision).
  - `upd2` — rejects all other drafts on the same outreach_item (so the item only has one alive draft post-approval).
  - `upd3` — `UPDATE outreach_items SET status='reviewed'` when decision ∈ {approved, manual_only, rejected}.
  - `pj` — `INSERT INTO publish_jobs (...) SELECT FROM ins WHERE $3 IN ('approved', 'manual_only')`. `publish_mode` is `manual_required` for `manual_only`, `postiz_scheduled` for `approved`. `destination_platform := ins.approved_platform` (the semantic string), `destination_account := ins.approved_destination` (the Postiz integration id). `payload_hash := ins.approved_content_hash`. `status='ready'`.
- `Build Confirmation HTML` → `Respond Confirmation` — returns the confirmation page.

### Sub-flow 4: POST /webhook/slack-interactive (Slack quick-approve / reject)

- `Webhook Slack Interactive` — no auth at the n8n level; verification is the next node.
- `Verify Slack Signature` — Code. Reconstructs the v0 signature base from `x-slack-request-timestamp` + raw `payload=<urlencoded>` body, HMAC-SHA-256 with `$env.SLACK_SIGNING_SECRET`, constant-time compare. Rejects ts drift > 300s. Parses the payload to get `verb` (`approve`/`reject`) and `outreach_item_id` from the button's `action_id` (e.g., `approve_1046`).
- `Look Up Draft` — Postgres. Fetches the `helpful_only` draft in `needs_human_review` for the item.
- `Check Draft + Route` — Code. Decides `_route`: `write` (approve+risk<20 OR reject), `risk_too_high` (approve+risk>=20), or `no_draft`.
- `Route Decision` — Switch with three outputs.
- `Build Slack Approval` — Code. **Embeds pure-JS SHA-256.** Hardcodes `platform = 'bluesky'` (Slack buttons have no platform picker today — TODO #1 in HANDOFF). Computes the 4-field hash matching the form path's shape.
- `Write Slack Approval (CTE)` — Same shape as the form path's CTE but the `pj` insert is gated on `decision='approved' AND length(approved_destination) > 0` (Followup 2 fix; commit `e205db1`). This means a Slack approve with empty destination still records the approval (good for triage) but doesn't enqueue a publish_job.
- `HTTP Confirm Approval` — POSTs to Slack's `response_url` with an ephemeral 3-state message: `:white_check_mark: dispatching to Postiz (job #N)` / `:warning: triage-only — no destination set` / `:x: Rejected`.
- `HTTP Risk Too High` — POSTs an ephemeral "use the form" message; no write.
- `HTTP No Draft` — POSTs `error_msg` for missing/already-handled drafts.

### Integrations / credentials

- `outreach-db-n8n`, `slack-bot-token` (`o9pysvcgZQFhoOLP`), `n8n-form-auth` (`wp5foUcxmwrXaaDk`), `postiz-api-key` (`pZtZApIkEy00000A`).
- Env: `SLACK_SIGNING_SECRET` (required for slack-interactive path), `POSTIZ_API_BASE_URL`, `POSTIZ_API_KEY` (header value sent by credential), `SLACK_OUTREACH_CHANNEL_ID` (informational; channel is actually hardcoded in node).

### DB touched

- Writes: `outcomes` (INSERT `notified` and is the legacy notifications log), `approvals` (INSERT one row per submit), `drafts` (UPDATE status — chosen draft set to `approved`/`rejected`; siblings rejected), `outreach_items` (UPDATE status → `reviewed`), `publish_jobs` (INSERT one row per approved/manual_only decision, status=`ready`).
- Reads: `outreach_items`, `drafts`, `outcomes` (for de-dupe of notifications), Postiz `/integrations` (HTTP).

### Failure modes / gotchas

- Slack interactive must be reachable at `https://n8n.corbello.io/webhook/slack-interactive` (configured in Slack App's interactivity settings). The signature check is strict — if `SLACK_SIGNING_SECRET` drifts or the systemd drop-in is missing, every button click 5xxs.
- The form path uses HTTP Basic auth (`n8n-form-auth`). Browsers will prompt on first visit; refresh-back to the form after submitting requires the auth to still be cached.
- The `Write Approval (CTE)` query depends on the `enforce_approval_match` trigger being installed — without it, the `pj` insert could write a mismatched destination/platform pair. The schema test harness defends this with `P0001` assertions.
- Slack quick-approve only works for Bluesky right now. Mastodon, LinkedIn, and future channels must go through the form.
- Hash payload shape change (Phase 2.1) added `approved_platform` to the SHA-256 input. Any in-flight `ready` job written under the old 5-field shape will fail Workflow D's hash check — verify there are zero `ready` rows before deploying a hash-shape change (B4 / Followup 2 pre-deploy gate).

---

## outreach-publish-dispatcher (`pUbLiShDiSpAtCh01`)

**File:** `apps/outreach-workflows/n8n/publish-dispatcher.json`
**Trigger:** `Schedule Trigger` every 2 min
**Phase:** 2
**One-line:** Polls `publish_jobs` for `ready` rows with `attempt_count < 3`, re-verifies the SHA-256 hash, routes by `publish_mode` to Postiz (or to `manual_post_required`), and rolls the parent `outreach_items` up to `published`.

### Pipeline position

The only mutator of `publish_jobs.status` (other than the `Mark Failed` retry path the operator might invoke manually). Reads `publish_jobs JOIN approvals JOIN drafts`. Writes `publish_jobs.status` (`sent_to_postiz` / `failed` / `manual_post_required`) and `outreach_items.status='published'`. Postiz then handles the actual social post; the outcome logger (not yet built) will reconcile Postiz callbacks back into our DB.

### Key nodes

- `Fetch Ready` — Postgres. Joins `publish_jobs JOIN approvals ON id JOIN drafts ON id`, projects `approved_*` columns + `COALESCE(edited_text, draft_text) AS final_text`. Filter: `pj.status='ready' AND attempt_count < 3`. Ordered by `scheduled_for NULLS FIRST, pj.id`. LIMIT 20.
- `Split In Batches` — size 1, output 1 carries the loop body.
- `Verify Hash` — Code. **Embeds the canonical pure-JS SHA-256.** Re-computes `sha256(final_text + approved_destination + approved_post_type + approved_platform)` and compares to `approved_content_hash`. Throws on mismatch. `onError: continueErrorOutput` wires failures to `main[1]` (memory `n8n-continueErrorOutput-routes-main1`) → `Mark Failed Hash`. Successful verify routes to `Route by publish_mode`.
- `Route by publish_mode` — Switch with three branches: `postiz_scheduled` and `postiz_immediate` both route to `Postiz Create Post`; `manual_required` routes to `Mark Manual`.
- `Postiz Create Post` — HTTP POST `$env.POSTIZ_API_BASE_URL/posts`, header-auth (raw key). Body uses Postiz's CreatePostDto shape: `type` is `'now'` for immediate or `'schedule'` for scheduled, `posts: [{integration: {id: destination_account}, value: [{content: final_text, image: []}]}]`, top-level `shortLink: false, date: now, tags: []`. `onError: continueErrorOutput` → `Mark Failed`.
- `Mark Sent` — Postgres. Sets `publish_jobs.status='sent_to_postiz', postiz_post_id=<id from Postiz>, sent_at=now()`. The queryReplacement reads from `$json.id || $json.postId || $json.post_id` — Postiz's response shape is not entirely consistent across endpoints, so the fallback chain matters.
- `Mark Failed` — Postgres. `status='failed', failure_reason=<first 500 chars>, attempt_count=attempt_count+1`. Returns to `Rollup outreach_items`.
- `Mark Failed Hash` — Postgres. Same shape as `Mark Failed` but invoked from the hash-mismatch path; failure_reason is `'Hash mismatch'`.
- `Mark Manual` — Postgres. Sets `status='manual_post_required'`. Workflow E (`outreach-manual-publish`) picks these up via the approval row's decision='manual_only'.
- `Rollup outreach_items` — Postgres. Sets the parent `outreach_items.status='published'` ONLY when no related publish_job is still in a non-terminal state. The `NOT EXISTS` subquery joins through `approvals → drafts → outreach_items`; safe to call on every successful path.

### Integrations / credentials

- `outreach-db-n8n`, `postiz-api-key`.
- Env: `POSTIZ_API_BASE_URL`, `POSTIZ_API_KEY`.

### DB touched

- Writes: `publish_jobs` (UPDATE status → `sent_to_postiz` / `failed` / `manual_post_required`, `postiz_post_id`, `sent_at`, `failure_reason`, `attempt_count`), `outreach_items` (UPDATE status → `published` via the NOT EXISTS rollup).
- Reads: `publish_jobs JOIN approvals JOIN drafts`.

### Failure modes / gotchas

- Postiz integration ID drift: if a Postiz integration is rotated/recreated, every `ready` row with the old ID will hard-fail at `Postiz Create Post`. There's no automatic re-targeting.
- The `Mark Sent` Postiz post id extraction (`$json.id || $json.postId || $json.post_id`) was hardened during T25. If the Postiz response shape changes, `postiz_post_id` will go empty silently — check the DB.
- `attempt_count < 3` is the retry budget. A job stuck failing for any reason auto-stops after 3 attempts; the operator must investigate and either retry (update status back to `ready` after fixing the root cause) or abandon (status `abandoned`, see HANDOFF migration `20260521120000`).
- Hash mismatch on rows written before Phase 2.1 (5-field shape) will fail forever — those rows must be marked `abandoned` (row 47 was the only one; commit `f2ae505`).
- `manual_post_required` rows do NOT flow through Workflow E directly. Workflow E reads `approvals` where `decision IN ('approved', 'manual_only')` and joins on `outcomes` to find unsent. The publish_job's status is mostly informational for `manual_only` — Workflow E is the actual operator-facing DM trigger.

---

## outreach-manual-publish (`mAnUaLpUbLiSh0001`)

**File:** `apps/outreach-workflows/n8n/manual-publish.json`
**Trigger:** `Schedule Trigger` every 2 min
**Phase:** 1
**One-line:** Finds approved approvals (any decision in `approved`/`manual_only`) that haven't yet been DM'd to the operator, sends a Slack DM with the approved text in a code fence ready to paste, logs the send.

### Pipeline position

Operator-in-the-loop publish path. Reads `approvals JOIN drafts JOIN outreach_items` and the `outcomes` table to find unsent rows. Writes only to `outcomes` (`kind='manual_dm_sent'`). Does NOT mutate `publish_jobs` — that's Workflow D's domain even for `manual_required` mode. Intended for channels that we can't automate yet (Reddit, X, LinkedIn pre-approval) or any approval the reviewer wanted to handle manually.

### Key nodes

- `Find Unsent Approvals` — Postgres. Selects approvals where `decision IN ('approved', 'manual_only')`, `expires_at > now()`, and not already in `outcomes` with `kind='manual_dm_sent'`. LIMIT 10.
- `Split In Batches` — size 1, loop body on output 1.
- `Build DM` — Code. Picks `edited_text` if present else `draft_text`. Builds a Slack Block Kit message: header section with approval id + destination + post-type + source link, divider, code-fenced text block. Sanitizes triple-backticks in the text body (replaces ` ``` ` with `` ` ` ` `` to avoid breaking the fence).
- `Slack Send DM` — Slack node, channelId set from `$env.SLACK_OUTREACH_OPERATOR_USER_ID` (Slack treats a user ID as a DM target). Requires the systemd drop-in to be present.
- `Log DM Sent` — Postgres. INSERT `outcomes (publish_job_id=NULL, notes=jsonb_build_object('approval_id', $1, 'kind', 'manual_dm_sent')::text)`.

### Integrations / credentials

- `outreach-db-n8n`, `slack-bot-token`.
- Env: `SLACK_OUTREACH_OPERATOR_USER_ID`.

### DB touched

- Writes: `outcomes` (INSERT `manual_dm_sent` notes row).
- Reads: `approvals JOIN drafts JOIN outreach_items`, `outcomes` (for de-dupe).

### Failure modes / gotchas

- Without `SLACK_OUTREACH_OPERATOR_USER_ID` in the systemd drop-in (and `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`), the Slack DM expression resolves to empty → Slack node 4xxs.
- This workflow runs against EVERY approved approval, including ones that Workflow D has already auto-published via Postiz. If you don't want a DM for `approved` rows that Postiz handles, filter the SELECT to `decision='manual_only'` only. Currently the operator gets a "ready to paste" message even when no manual action is needed — useful as an audit trail but noisy.
- `outcomes.publish_job_id` is intentionally NULL here because the DM-sent fact pre-dates the publish_job lifecycle. Don't refactor to require a non-null publish_job_id.

---

## outreach-expire-stale (`eXp1rEsTaLeWf001`)

**File:** `apps/outreach-workflows/n8n/expire-stale.json`
**Trigger:** `Schedule Trigger` daily at 03:00 UTC
**Phase:** 1
**One-line:** Expires drafts stuck in `needs_human_review` for >14 days, expires approvals whose `expires_at` has passed, posts a summary to `#plotlens-outreach`.

### Pipeline position

Janitor workflow. Reads + writes `drafts` and `approvals` only — doesn't touch `outreach_items` or `publish_jobs`. Slack summary is informational. Runs at a quiet hour to avoid contending with the every-2-min loops.

### Key nodes

- `Expire Drafts` — Postgres. `UPDATE drafts SET status='expired' WHERE status='needs_human_review' AND created_at < now() - INTERVAL '14 days' RETURNING id`.
- `Expire Approvals` — Postgres. `UPDATE approvals SET decision='rejected', approval_notes = COALESCE(approval_notes,'') || ' [auto-expired]' WHERE decision='approved' AND expires_at < now() RETURNING id`.
- `Aggregate Counts` — Code. Counts items from the two prior nodes via `$('Expire Drafts').all().length`. Builds a Slack section block.
- `Slack Post Summary` — Slack node, channelId hardcoded `C0B4SUTP8R4`.

### Integrations / credentials

- `outreach-db-n8n`, `slack-bot-token`.

### DB touched

- Writes: `drafts` (UPDATE status → `expired`), `approvals` (UPDATE decision → `rejected`, appends `[auto-expired]` to `approval_notes`).
- Reads: same tables (the UPDATE ... RETURNING returns ids for the count).

### Failure modes / gotchas

- Expiring an approved approval flips it to `rejected` — it doesn't delete the associated `publish_jobs` row. If a `ready` publish_job's approval is expired this way, Workflow D will still try to dispatch it (the trigger doesn't re-check expires_at on the approval). In practice this is fine because `expires_at` is set far enough out that it predates `ready` rows aging into expiry, but if you ever extend expiry semantics, also gate Workflow D's `Fetch Ready` on `a.expires_at > now()`.
- Drafts expired here cannot be approved (no UI re-renders them). They stay in the DB as a history record.

---

## outreach-smoke (`sMoKeOutreachW001`)

**File:** `apps/outreach-workflows/n8n/smoke.json`
**Trigger:** `Schedule Trigger` daily at 09:00 UTC
**Phase:** 1
**One-line:** Fires a synthetic POST at the Discover webhook, waits 5 min, verifies the row reached `drafted` or `reviewed`, alerts Slack on failure, cleans up synthetic rows older than 1 hour.

### Pipeline position

End-to-end watchdog for Workflows A → B. Doesn't exercise the review/dispatch path (only checks status reached `drafted` or `reviewed`). Source URLs follow the pattern `https://plotlens.ai/smoke-test/YYYY-MM-DD`; cleanup uses this prefix to identify synthetic rows.

### Key nodes

- `Build Smoke URL` — Code. Generates `https://plotlens.ai/smoke-test/<today YYYY-MM-DD>`.
- `Trigger Discover` — HTTP POST to `https://n8n.corbello.io/webhook/outreach-discover`, header-auth via `discover-webhook-secret`.
- `Wait` — 5 min n8n Wait node (uses webhook resume `smoke-wait-resume`).
- `Check Drafted Status` — Postgres. `SELECT ... WHERE source_url = $1 AND status IN ('drafted', 'reviewed') LIMIT 1`.
- `Smoke OK?` — IF on `$('Check Drafted Status').all().length > 0`. False branch → alert.
- `Build Alert Blocks` + `Slack Alert` — channelId hardcoded `C0B4SUTP8R4`, `:rotating_light:` block.
- `Cleanup Old Smoke Rows` — Postgres. Two-statement DELETE: drafts for smoke-test items older than 1 hour first (no `ON DELETE CASCADE`), then the items themselves. Skips any whose drafts have an approval row (defensive — shouldn't happen in normal operation).

### Integrations / credentials

- `outreach-db-n8n`, `slack-bot-token`, `discover-webhook-secret`.

### DB touched

- Writes: `outreach_items` (DELETE for >1h-old smoke rows), `drafts` (DELETE for those items' drafts first). Indirect: `outreach_items` INSERT happens via Workflow A as a side effect of the synthetic webhook POST.
- Reads: `outreach_items` (status check).

### Failure modes / gotchas

- The Wait node resumes via webhook (`smoke-wait-resume`). If n8n restarts during the 5-min window, the resume is lost and the alert never fires for that day — the cleanup still runs the next day.
- A daily run takes ~5 min wall-time but holds an execution slot the whole time; if n8n is heavily loaded, the wait may extend.
- Cleanup only deletes synthetic rows >1 hour old AND with no approvals. If you ever approve a smoke-test draft (don't), the row will persist until manually deleted.
- The smoke URL changes daily, so duplicates are impossible day-to-day but `ON CONFLICT DO NOTHING` in Workflow A handles the same-day case if the workflow is double-triggered.

---

## Where to look when X breaks

| Symptom | Look here first |
|---|---|
| Slack approval gets no follow-up message after click | `outreach-review-notify` → `Verify Slack Signature` (most likely `SLACK_SIGNING_SECRET` drift / missing systemd drop-in / clock skew >300s). Then `Check Draft + Route` (the `helpful_only` draft may already be `approved`/`rejected`). |
| `publish_jobs` row stuck in `ready` (not picked up) | `outreach-publish-dispatcher` → `Fetch Ready` (is the job's `attempt_count >= 3`? Then it won't be picked up. Reset to retry, or mark `abandoned`). Check the workflow is `active` and the schedule trigger is firing. |
| Postiz post fails | `outreach-publish-dispatcher` → `Postiz Create Post` (look at `publish_jobs.failure_reason` for the captured error). Common causes: stale integration ID, missing `POSTIZ_API_KEY`, Postiz pod restarting. Cross-check against the live `/api/public/v1/integrations` response. |
| Hash mismatch — `publish_jobs.failure_reason = 'Hash mismatch'` | `outreach-publish-dispatcher` → `Verify Hash`. Most likely cause: the row was written under the pre-Phase-2.1 5-field hash shape (row 47 was the only such case — abandoned). If it's a new row, re-confirm all five sha256 copies are bit-for-bit identical via `node apps/outreach-workflows/tests/sha256-audit/audit.js`. |
| Discord/Slack smoke alert fires (`Outreach smoke FAILED`) | `outreach-smoke` → `Check Drafted Status`. Then check Workflows A and B: did Workflow A's webhook accept the synthetic URL? Did Workflow B's `Call Anthropic` fail or skip the item? Inspect `outreach_items` for the day's smoke URL — what status is it in? |
| Approval form loads but channel dropdown is empty | `outreach-review-notify` → `Fetch Postiz Integrations`. Check `POSTIZ_API_BASE_URL` env var is set and Postiz pod is healthy. The `Code Render HTML` node renders an error page when integrations.length is 0. |
| Form submit returns "Invalid or missing approved_platform" | `outreach-review-notify` → `Build Approval`'s whitelist (`bluesky`/`mastodon`/`reddit`/`x`/`linkedin`). Likely the unified-dropdown `onchange` didn't fire — try resubmitting; if persistent, inspect the rendered HTML form's `data-platform` attributes. |
| Operator never gets the "ready to paste" DM | `outreach-manual-publish` → `Find Unsent Approvals` (is `approvals.expires_at > now()` and no `outcomes` row with `kind='manual_dm_sent'` for this approval?). Then check `Slack Send DM` (is `SLACK_OUTREACH_OPERATOR_USER_ID` populated?). |
| `enforce_approval_match` trigger raises `P0001` on insert | The CTE that did the INSERT had a mismatch between `approvals.approved_*` and the `publish_jobs.destination_*` / `payload_hash`. Re-read `Write Approval (CTE)` or `Write Slack Approval (CTE)` — every `pj` column should reference `ins.*`, not the raw queryReplacement params. |
| Drafts not getting created despite items in `discovered` | `outreach-draft` → `Fetch Candidates` (items may be in `drafting` from a prior failed run — they'd block via `FOR UPDATE SKIP LOCKED`). Or `Call Anthropic` is failing (check the workflow execution log). |

## Quick operational queries

These are the SQL snippets used most often when triaging the pipeline. Run via `ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c '<SQL>'\""` (the credential-less escape hatch — memory `lxc-114-credential-less-psql`).

```sql
-- Pipeline census by stage
SELECT status, count(*) FROM outreach_items GROUP BY status ORDER BY count DESC;
SELECT status, count(*) FROM drafts GROUP BY status ORDER BY count DESC;
SELECT status, count(*) FROM publish_jobs GROUP BY status ORDER BY count DESC;

-- Oldest ready job (this is the metric postgres_exporter emits)
SELECT id, destination_platform, destination_account, attempt_count,
       EXTRACT(EPOCH FROM (now() - created_at)) AS age_seconds
FROM publish_jobs WHERE status='ready' ORDER BY created_at LIMIT 5;

-- Recent failures (look at failure_reason for the captured error string)
SELECT id, destination_platform, attempt_count, failure_reason
FROM publish_jobs WHERE status='failed' ORDER BY id DESC LIMIT 10;

-- Approvals not yet DM'd (what manual-publish would pick up next tick)
SELECT a.id, a.decision, a.approved_destination, oi.source_url
FROM approvals a
JOIN drafts d ON d.id=a.draft_id
JOIN outreach_items oi ON oi.id=d.outreach_item_id
WHERE a.decision IN ('approved','manual_only') AND a.expires_at > now()
  AND a.id NOT IN (SELECT (notes::jsonb->>'approval_id')::bigint FROM outcomes
                   WHERE notes::jsonb ? 'approval_id'
                     AND notes::jsonb->>'kind'='manual_dm_sent')
ORDER BY a.id;

-- Manually retry a failed job (after fixing the root cause)
UPDATE publish_jobs SET status='ready', failure_reason=NULL, attempt_count=0 WHERE id=<n>;

-- Abandon a permanently-broken job (won't be picked up by Workflow D)
UPDATE publish_jobs SET status='abandoned' WHERE id=<n>;
```

When in doubt, the workflow execution log in the n8n UI (Executions tab) shows every node's input/output for failed runs. That plus the per-row `failure_reason` and `outcomes` audit trail covers most triage.
