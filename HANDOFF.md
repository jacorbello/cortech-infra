# PlotLens Outreach — Session Handoff

**As of:** 2026-05-22 — Phase 2.1 schema cleanup + 11 followups + X investigation + 6 DEPLOYED + 10 CI drift guards landed. **Followup 11 (Assert return-shape + Normalize RSS excerpt fallback + thin-skip) deployed 16:22 UTC — Issue A & B from prior handoff now closed.**
- A1-A3 + B1-B7 schema/UX cleanup
- Followups: unified channel dropdown, Slack quick-approve dispatch, schema test SQLSTATE hardening, X investigation
- **Slack platform-picker deployed to LXC 112** at 17:09 UTC (workflow `rEv1eWoUtReAcH001`)
- **outreach-smoke heartbeat fix deployed to LXC 112** at 18:36 UTC (workflow `sMoKeOutreachW001`) — root-caused via systematic-debugging: was silently failing since first scheduled run because `/etc/hosts` in LXC 112 maps `n8n.corbello.io → 127.0.1.1` (PVE auto-managed because container hostname is `n8n`); fix swaps the self-loop URL to `http://127.0.0.1:5678/webhook/outreach-discover` + adds error-output Slack alert wiring so HTTP-layer failures page directly
- **Slack blocksUi + form dedup fix deployed to LXC 112** at 19:35 UTC (4 workflows: `rEv1eWoUtReAcH001`, `eXp1rEsTaLeWf001`, `mAnUaLpUbLiSh0001`, `sMoKeOutreachW001`) — root-caused via systematic-debugging: Slack v2 node (typeVersion 2.3) reads `blocksUi` with `ensureType: 'object'` which accepts bare arrays; `Slack/V2/GenericFunctions.js:194` then looks for `.blocks` on the value; bare array has no `.blocks` so the spread into the request body produces integer keys and `chat.postMessage` never receives `blocks`. Slack falls back to text-only render. Bug present since workflows authored. Fix: `={{ JSON.stringify($json.slack_blocks) }}` → `={{ { blocks: $json.slack_blocks } }}` in all 4 nodes. Also fixed form dropdown showing 9 options for 3 integrations: upstream `Fetch Postiz Integrations` fanned out per draft (3 drafts × 3 fetches = 9 integration items); dedup-by-id in `Code Render HTML` reduces to N unique. Added `Assert Slack Blocks Sent` Code node in review.json that throws if Slack drops blocks silently. Added `blocksui-shape-audit.js` CI lint.
- **Slack signature + parser hardening fix deployed to LXC 112** at 20:39 UTC (workflow `rEv1eWoUtReAcH001`) — root-caused via systematic-debugging: JavaScript `encodeURIComponent` vs Go `url.QueryEscape` encoder mismatch on `( ) ' * ~ ! +` characters meant HMAC reconstruction never matched what Slack signed. Fix: enable `rawBody` on Webhook Slack Interactive, HMAC over the actual base64 bytes Slack sent. Also: parser short-circuits unknown verbs (link-button telemetry callbacks like `e/DS5` no longer error), stable `open_form_<oid>` action_id on Open Full Form, new `Actionable Verb?` IF gate routes ignore-verb to existing Respond 200. Two new CI guards: `webhook-rawbody-audit` (asserts `options.rawBody` on HMAC-bound webhooks), `slack-signature-end-to-end` (Go-encoded synthetic payload tested through the real Code node sandbox — 16/16 pass).
- **RSS expansion + follow.it cleanup + soft-block bundle deployed to LXC 112** at 22:10 UTC (workflow `dScvr0utReAcHW01`) — feed list now 10 active feeds (Reedsy removed as dead; added Writer Unboxed, Kill Zone Blog, Writers in the Storm, John August, Go Into The Story, Steven Pressfield). `Normalize RSS` gained `unwrapFollowIt(url)` helper that resolves the canonical URL via single HEAD redirect (only for `api.follow.it/*` hosts; 3s timeout; falls back to original on any error). Two new `Apply Soft Block` Code nodes (RSS path + manual webhook path) with `SOFT_BLOCK_PATTERNS` array: `annerallen.com`, `countercraft.substack.com`, `reddit.com/r/writing` (word-boundary regex so r/writingadvice and friends still allowed). New `scripts/backfill-followit-urls.sh` (DRY-RUN default, `--apply` flag) for one-time canonicalization of existing 20 follow.it rows — NOT yet executed. New `normalize-rss-no-followit.js` CI audit functionally tests the helper via VM sandbox.
- **Followup 11 (Assert return-shape + Normalize RSS excerpt fallback + thin-skip) deployed to LXC 112** at 2026-05-22 16:22 UTC (workflows `rEv1eWoUtReAcH001` + `dScvr0utReAcHW01`) — root-caused both prior-handoff blockers via systematic-debugging. **Issue B (duplicate Slack notifications):** `Assert Slack Blocks Sent` Code node was `mode: runOnceForEachItem` but returned `[{ json: $json }]` (array-wrapped); n8n's `validateRunCodeEachItem` walks the array and tries `.json` on the array itself (undefined) → throws `"A 'json' property isn't an object [item 0]"`. The throw fired AFTER Slack posted but BEFORE `Log Notification` (dedup write) — so `outcomes` never got a `notified` row and the next 2-min cycle re-fetched + re-posted. Bounded at 2 stuck items × ~195 cycles = 220 errored executions over ~13h. Fix: `return [{ json: $json }];` → `return { json: $json };` in that one node. **Issue A ("No usable excerpt" drafts):** new RSS feeds (Writer Unboxed, Kill Zone Blog, etc.) emit thin/empty `contentSnippet` for items 2263-2277 (`LENGTH(source_excerpt)=0`). Fix in `Normalize RSS`: excerpt fallback chain `contentSnippet || content || description || ''`, strip HTML tags, collapse whitespace, AND skip-at-discover-time when final excerpt < 50 chars (item never enters `outreach_items` so the drafter never wastes tokens on emptiness). Deeper follow.it 2nd-redirect issue (helper returns `follow.it` homepage instead of canonical) NOT addressed here — left as future work. Two new CI guards wired into `sha256-audit`: `code-node-return-shape-audit.js` rejects `runOnceForEachItem` Code nodes returning `[{ json: ... }]` (Workflow D's `publish-dispatcher.json:Verify Hash` grandfathered with inline-citation reasoning — T25 row 62 SUCCESS proved n8n tolerates the pattern in some upstream-node shapes; out of scope for this bundle); `normalize-rss-thin-excerpt-skip.js` sandbox-runs the new code with 6 input vectors (3 kept + 3 skipped). Existing `normalize-rss-no-followit.js` fixture lengths bumped past the 50-char threshold so the older guard still passes. Pre-deploy validated; post-restart at 16:22:38 UTC the first review-notify cycle wrote `outcomes` row 30 (`{"kind":"notified","outreach_item_id":2268}`) confirming Assert fix + Log Notification + dedup all live. **Cleanup pending user authorization in chat:** `outreach_items` 2263-2277 → `archived` (15 thin-excerpt rows); item #2268 drafts → `rejected` + item → `reviewed`; #2258 (3 good Joanna Penn / Nadim Sadek drafts) left for user to approve via Slack now that buttons work; #2259-2262 (good 1000-char excerpts) still flowing through the drafter. Not touching LXC 112 further this session.
- CI drift guards added: PLATFORM_MAP sync, full sha256 helper-family bit-identity (catches `sha256Raw` inside `hmacSha256`), hash-payload concat-order pin, no-public-self-loop URL check, blocksUi-shape guard, webhook-rawbody audit, Slack-signature end-to-end, normalize-rss-no-followit, **code-node-return-shape**, **normalize-rss-thin-excerpt-skip** (10 guard scripts; audit.js assertion count: 23 → 37, holding steady at 37 this round; the 2 new guards add their own self-contained checks)
- X channel deferred indefinitely (paid plan cost)
- 4 code-quality minors from earlier review addressed

**User context (active session boundary):** Jeremy is actively using n8n for Phase 1 operational validation. Treat live workflows on LXC 112 as in-use — do NOT re-import/restart n8n.service without explicit confirmation. Read-only DB queries via `pct exec 114` are fine.

**Branch:** `outreach/phase0-phase1` (pushed)
**Draft PR:** https://github.com/jacorbello/cortech-infra/pull/18 — MERGEABLE, all 4 CI checks SUCCESS at HEAD `7ad32a9` (schema / audit / sha256-audit / manifests-lint). sha256-audit now 37 pass + 7 drift guards (PLATFORM_MAP, sha256 helper-family, hash-payload concat-order, no-public-self-loop, blocksui-shape, webhook-rawbody, slack-signature end-to-end).
**Phase 1 spec:** `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md`
**Phase 1 plan:** `docs/superpowers/plans/2026-05-19-plotlens-outreach-phase0-and-phase1.md`
**Phase 2 spec:** `docs/superpowers/specs/2026-05-20-plotlens-outreach-phase2-design.md`
**Phase 2 plan:** `docs/superpowers/plans/2026-05-20-plotlens-outreach-phase2.md`
**Living roadmap:** `docs/superpowers/roadmaps/plotlens-outreach.md`

Read this file first on any session resume. Safe to delete once Phase 2 is tagged.

## Where we are right now

**Phase 1:** ALL 34 tasks BUILT. Operational validation (10 real items end-to-end) NOT done. NOT tagged.

**Phase 2:** T1-T29 done + Phase 2.1 schema cleanup done (A1-A3 + B1-B7 + B5.5) + 10 followups (unified dropdown, Slack dispatch, schema test hardening, X investigation, Slack platform-picker DEPLOYED, CI drift guards, smoke fix DEPLOYED, Slack blocksUi + form dedup DEPLOYED, Slack signature fix DEPLOYED, RSS + follow.it + soft-block DEPLOYED). T30 is the exit gate — it can't be tagged until:
1. Phase 1 is tagged first (exit criterion 9).
2. At least 5 production `publish_jobs` rows succeed (currently 1 — row 62 from T25, status `sent_to_postiz`, Postiz post id `cmpel07680002j0au2phuim4q`). The B7 synthetic smoke-test row 63 was cleaned up at task time; the live Bluesky post it produced (`cmpfkq5x80003j0aulvbz98h4`) was manually deleted by the user 2026-05-21.
3. ArgoCD `temporal` + `postiz` Applications stay Synced/Healthy for 24h. The 24h clock effectively restarted at the platform-picker reactivation (commit `a364a04` deployed 2026-05-21 17:09 UTC).

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
| B7 | ✅ | End-to-end smoke test: synthetic publish_jobs row dispatched through Workflow D's Verify Hash with the new 6-field payload, posted live to Bluesky — test post `cmpfkq5x80003j0aulvbz98h4` was manually deleted by user 2026-05-21. |
| B8 | ✅ | HANDOFF refresh + push (commit `4855507`) + CI green wait. CI fixup `fcb0496` ("include approved_platform in trigger enforcement tests") required because the pre-hardening run_expect_fail accepted NOT NULL violations as the trigger firing — exposed the test-harness gap that became known-issue #12. |
| Followup 1 — Unified channel dropdown | ✅ | One `<select name="approved_destination">` where each option is a Postiz integration (value=integration id, data-platform=platform identifier). Hidden `approved_platform` field synced via inline `onchange`. Eliminates the mismatched-pair class entirely (commit `7122e4a`). |
| Followup 2 — Slack quick-approve dispatch | ✅ | `Write Slack Approval (CTE)` gained a `pj` CTE gated on `decision='approved' AND length(approved_destination) > 0`. Build Slack Approval's hash payload now includes platform (matching Workflow D's verify shape). HTTP Confirm Approval ephemeral message differentiates dispatched / triage-only / rejected. Platform hardcoded to `'bluesky'` for now (Slack buttons have no platform-picker UI — see TODOs) (commit `e205db1`). |
| Followup 3 — Schema test SQLSTATE hardening | ✅ | `run_expect_fail` now takes an expected SQLSTATE arg (was: accepted any non-zero exit). psql runs with `VERBOSITY=verbose` so the harness can grep for `ERROR:  <SQLSTATE>:`. All 3 trigger enforcement tests now assert `P0001`. Sanity-verified: dropping a NOT NULL column from a test INSERT now correctly fails with "SQLSTATE was not P0001" instead of silently passing (commit `bb0c684`). |
| Followup 4 — X channel investigation | ✅ | Root cause of "Could not connect to the platform" toast: missing `X_API_KEY`/`X_API_SECRET` env vars; Postiz backend's `try/catch` at `integrations.controller.ts:225-245` swallows the TwitterApi auth error and returns `{err:true}`. X tile shows because the provider list has no env-gate. Updated `docs/runbooks/postiz-channel-onboarding.md` X section with current paid-plan reality + OAuth 1.0a (not 2.0) detail + exact callback URL. User-deferred indefinitely 2026-05-21 (commit `d981df6`). |
| Followup 5 — Slack platform-picker | ✅ | `Build Slack Blocks` now emits one "Approve → <platform>" button per Postiz integration (PLATFORM_MAP: bluesky_brand, mastodon, bluesky_personal). `Verify Slack Signature` parses tri-segment `approve_<platform_key>_<oid>` action_ids. `Build Slack Approval` resolves platform_key into (platform, integration ID) and emits a correctly-shaped hash payload (matches Workflow D Verify Hash). `Write Slack Approval (CTE)` unchanged. `HTTP Confirm Approval` surfaces the picked platform in the ephemeral reply. Channel-onboarding sync rule documented in `docs/runbooks/postiz-channel-onboarding.md` (commit `a364a04`). **DEPLOYED 2026-05-21 17:09 UTC** — `n8n import:workflow` + `update:workflow --active=true` + `systemctl restart n8n.service`; n8n healthy 2s post-restart, journal confirmed `Activated workflow "outreach-review-notify"`, DB `active=1`. |
| Followup 6 — CI drift guards for platform map + HMAC + hash payload order | ✅ | Three new tests under `apps/outreach-workflows/tests/sha256-audit/`: (1) `platform-map-audit.js` asserts the PLATFORM_MAP duplicates in `Build Slack Blocks` and `Build Slack Approval` stay in sync + each `integration` matches `^cmpe[a-z0-9]{20,}$` + each `platform` is in the schema CHECK set; (2) `audit.js` extended to extract EVERY `function sha256*` body (catches the previously-uncovered `sha256Raw` inside `hmacSha256`) and to run 4 RFC 4231 + 2 Slack v0 signing-base vectors against the live `hmacSha256` helper; (3) `hash-payload-order.js` fixture-runs `Build Approval` / `Build Slack Approval` / `Verify Hash` against a precomputed reference hash and pins the canonical concat tail `[destination, postType, platform]`. All three wired into the `sha256-audit` CI job. Negative-tests verified each guard catches real drift. Audit count: 23 → 37 pass (commits `4e90e95`, `4d18467`, `999db7d`). |
| Followup 7 — Smoke heartbeat fix + no-public-self-loop drift guard | ✅ | **DEPLOYED 2026-05-21 18:36 UTC.** Root cause via systematic-debugging: smoke's `Trigger Discover` POSTed to `https://n8n.corbello.io/webhook/outreach-discover` from inside LXC 112, where `/etc/hosts` maps that hostname to `127.0.1.1` (PVE auto-managed because container hostname is `n8n`); nothing listens on `127.0.1.1:443` so every run errored at the first HTTP call. Critical correction: bug was present from day one — only 2 scheduled runs ever fired (2026-05-20 + 2026-05-21 at 14:00 UTC because `GENERIC_TIMEZONE=America/Chicago`, not 09:00 UTC as the workflow description claims); both errored in 23ms. Fix: (1) `Trigger Discover.parameters.url` → `http://127.0.0.1:5678/webhook/outreach-discover`; (2) `Trigger Discover.onError = continueErrorOutput`; (3) new `Build HTTP Failure Alert` Code node wired to `main[1]` error output → existing `Slack Alert` (HTTP-layer failures now page, where before the alert path was downstream of the failing node). Also (4) new CI guard `no-public-self-loop.js` rejects any HTTP node URL containing `n8n.corbello.io` to prevent the bug class. Workflow re-imported + reactivated + restarted on LXC 112; healthy 2s post-restart; journal confirms `Activated workflow "outreach-smoke"` at 18:36:40. Did NOT change the schedule timezone (Chicago vs UTC is a doc cleanup, not a bug). Commits `d92ae02`, `dba7ace`. |
| Followup 8 — Slack blocksUi shape fix + form dropdown dedup + guardrails | ✅ | **DEPLOYED 2026-05-21 19:35 UTC.** Root cause via systematic-debugging: Slack v2 node (typeVersion 2.3) reads `blocksUi` with `ensureType: 'object'`, which accepts a bare array; `Slack/V2/GenericFunctions.js:194` then treats the value as an object expecting `.blocks` — bare array has none, so the spread into the request body produces integer keys (`"0"`, `"1"`) and `chat.postMessage` never receives `blocks`. Slack posts only `text` and server-renders it as a synthetic `rich_text` block. Bug present since workflows authored — explains why outreach-bot Slack messages never showed approve/reject buttons. Fix: 4 nodes' `parameters.blocksUi` changed from `={{ JSON.stringify($json.slack_blocks) }}` to `={{ { blocks: $json.slack_blocks } }}` (object wrapper). Separately: form dropdown was showing 9 options for 3 integrations because `Fetch Postiz Integrations` runs once per input item (n8n default) and `Postgres Load Drafts` emits 3 items, so 3 drafts × 3 fetches = 9 integration entries. Dedup-by-id in `Code Render HTML` reduces to N unique. New `Assert Slack Blocks Sent` Code node in review.json throws on silent drop. New `blocksui-shape-audit.js` CI guard rejects any `messageType: block` Slack node with broken expression. 4 workflows imported, all 4 reactivated, single n8n restart; healthy 2s post-restart; journal shows all 4 `Activated workflow` lines; DB confirms all 4 `active=1`; broken expression count in DB = 0. Commits `43b3251`, `5c283ec`. |
| Followup 9 — Slack signature + parser hardening | ✅ | **DEPLOYED 2026-05-21 20:39 UTC.** Root cause via systematic-debugging: `Verify Slack Signature` reconstructed the signed string by feeding the parsed `payload` JSON back through JavaScript `encodeURIComponent`, but Slack signs the bytes its Go server actually sent — produced by `url.QueryEscape`. The two encoders disagree on `( ) ' * ~ ! +` and space; any real Slack callback containing those characters (usernames with apostrophes, action values with parens, etc.) failed HMAC reconstruction and got rejected with `Invalid Slack signature` 401s. Fix: enable `options.rawBody=true` on `Webhook Slack Interactive` so n8n attaches the original request bytes under `item.binary.data` (base64); the verify node HMAC's those bytes directly — no re-encoding, no encoder-divergence surface. Secondary defect surfaced by the same incident: the "Open full form" link button had no explicit `action_id`, so Slack auto-assigned telemetry callbacks like `e/DS5`; even after fixing signatures the action_id parser threw `Malformed action_id`. The button now ships a stable `open_form_<oid>`, the parser returns `{verb: 'ignore'}` for any non-actionable verb (including `open_form` and unknown auto-IDs), and a new `Actionable Verb?` IF gate between `Verify Slack Signature` and `Look Up Draft` routes ignored verbs straight to an existing 200 response without touching the DB. Two new CI guards added to the `sha256-audit` job: `webhook-rawbody-audit.js` asserts every HMAC-bound Slack webhook carries `options.rawBody === true`; `slack-signature-end-to-end.js` builds a Go-`url.QueryEscape`-encoded synthetic Slack payload, runs it through the live `Verify Slack Signature` Code node sandbox, and asserts all 16 vectors (apostrophes, parens, tildes, plus signs, spaces, multibyte UTF-8) verify correctly. Pre-deploy gate: 0 ready rows confirmed. Workflow re-imported + reactivated + restarted; healthy 1s post-restart; journal shows `Activated workflow "outreach-review-notify"`; DB confirms `active=1`, `options.rawBody` present, `open_form_` pattern present, `Actionable Verb?` IF node present. Commit `7ad32a9`. |
| Followup 10 — RSS expansion + follow.it cleanup + soft-block bundle | ✅ | **DEPLOYED 2026-05-21 22:10 UTC + backfill applied same session.** Feed list expanded from 5 → 10 active (Reedsy removed as dead; added Writer Unboxed, Kill Zone Blog, Writers in the Storm, John August, Go Into The Story, Steven Pressfield). `Normalize RSS` gained `unwrapFollowIt(url)` helper: HEAD-with-manual-redirect for `api.follow.it/*` hosts, parses canonical from `Location` header's `?q=<urlencoded>` param, 3s timeout, falls back to original on any error. Two `Apply Soft Block` Code nodes (RSS path + manual webhook path) with `SOFT_BLOCK_PATTERNS` = annerallen.com / countercraft.substack.com / `reddit\.com\/r\/writing\b` (word-boundary so r/writingadvice etc. still allowed). Backfill via `scripts/backfill-followit-urls.sh --apply` canonicalized 20 historical follow.it rows to thecreativepenn.com permalinks (0 conflicts, 0 skips). New `normalize-rss-no-followit.js` CI audit functionally tests the helper via VM sandbox with stubbed fetch. Workflow re-imported + reactivated + restarted; healthy 2s post-restart; DB confirms `Apply Soft Block` node, `unwrapFollowIt` helper, word-boundary regex, all 6 new feeds, Reedsy fully removed. Commits `8b22ccf`, `e1a0219` (regex widening fixup), `6473b1c`+`13de101` (regex tightening + JSON re-indent), `9f5a5ea` (HANDOFF). |
| Followup 11 — Assert return-shape + Normalize RSS excerpt fallback + thin-skip | ✅ | **DEPLOYED 2026-05-22 16:22 UTC.** Closes both blockers from prior handoff. **Issue B (dup notifications) root cause:** `Assert Slack Blocks Sent` Code node in `apps/outreach-workflows/n8n/review.json` had `mode: runOnceForEachItem` but returned `[{ json: $json }]` array-wrapped; n8n's `validateRunCodeEachItem` in each-item mode expects bare `{ json: ... }` and walks the array trying `.json` on the array itself (undefined) → throws `"A 'json' property isn't an object [item 0]"` AFTER Slack posted but BEFORE the downstream `Log Notification` dedup write ran. `outcomes` never recorded a `notified` row, so the next 2-min review-notify cycle re-fetched + re-posted via the dedup-aware query. Bounded at 2 stuck items (#2258 + #2268) × ~195 cycles = 220 errored executions over ~13h. **Fix:** `return [{ json: $json }];` → `return { json: $json };` in that one node. **Issue A (useless drafts) root cause:** new RSS feeds (Writer Unboxed, Kill Zone Blog, Writers in the Storm, John August, Go Into The Story, Steven Pressfield) emit thin/empty `contentSnippet` — items 2263-2277 all had `LENGTH(source_excerpt)=0` after `Normalize RSS` (`apps/outreach-workflows/n8n/discover.json`); Sonnet then drafted useless "No usable excerpt or community context was found..." copy. **Fix in this bundle:** extend `Normalize RSS` excerpt extraction to fall back through `contentSnippet || content || description || ''`, strip HTML tags, collapse whitespace; thin-excerpt skip at discover-time — items with final excerpt < 50 chars are dropped before insertion into `outreach_items` so Sonnet never sees emptiness. **Out of scope (future work):** the `unwrapFollowIt` helper added in Followup 10 doesn't actually unwrap most follow.it tracking URLs because the first HEAD redirect for `api.follow.it/track-rss-story-click/v3/<opaque>` returns the follow.it homepage, not the canonical article — silent fallback, no crash, URLs stay as tracking proxies. **CI guards (both wired into `outreach-ci.yml` `sha256-audit`):** `code-node-return-shape-audit.js` rejects any `runOnceForEachItem` Code node returning `[{ json: ... }]`; Workflow D's `publish-dispatcher.json:Verify Hash` grandfathered with inline-citation reasoning (T25 row 62 SUCCESS suggests n8n tolerates the pattern in some upstream-node shapes; touching Workflow D is out of scope per session boundary — see task #128). `normalize-rss-thin-excerpt-skip.js` sandbox-runs the new code with 6 input vectors covering the contentSnippet/content/description fallback chain, the thin-skip threshold, and HTML stripping (3 kept + 3 skipped). Existing `normalize-rss-no-followit.js` fixture lengths bumped past the 50-char threshold so the older guard still passes. Audit count: 37 → 47 pass after this bundle (audit.js itself still 37 pass; +2 new guards add their own checks). **Post-deploy validation:** journal at 16:22:03 UTC shows `Activated workflow "outreach-discover"` + `Activated workflow "outreach-review-notify"`; n8n healthy 2s post-restart; the first post-restart review-notify cycle at 16:22:38 UTC wrote `outcomes` row id 30 (`{"kind":"notified","outreach_item_id":2268}`) — confirming Assert fix works, `Log Notification` runs, and dedup will now suppress re-notifications. **Cleanup pending user authorization in chat:** `UPDATE outreach_items SET status='archived' WHERE id BETWEEN 2263 AND 2277 AND status='drafting' AND (source_excerpt IS NULL OR LENGTH(source_excerpt) < 50)` (15 rows); `UPDATE drafts SET status='rejected' WHERE outreach_item_id=2268 AND status='needs_human_review'` (3 drafts) + `UPDATE outreach_items SET status='reviewed' WHERE id=2268`. NOT touched: #2258 (3 good Joanna Penn / Nadim Sadek drafts in needs_human_review — user should approve via Slack now that buttons work), #2259-2262 (good 1000-char excerpts still drafting). Commit `d7cd71c455688cda3cc5ca49d8d78fe8a42bcb9c`. |

## Top priority next session

Issue A and Issue B from the prior handoff are both **RESOLVED** as of Followup 11 (2026-05-22 16:22 UTC). The dedup row `outcomes` id 30 written at 16:22:38 UTC confirms the Assert fix + Log Notification + dedup query are all live. Issue A's thin-excerpt skip prevents future useless drafts; the follow.it 2nd-redirect deeper issue is parked as future work.

Resume priorities in order:

### (a) Confirm cleanup ran

The Followup 11 deploy left a planned-but-unauthorized cleanup. **If the user has not yet authorized it in chat, this is the first thing to do on resume.** Verify state first, then run only if user gives the go-ahead:

```bash
# Read-only audit before doing anything
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT id, status, LENGTH(source_excerpt) AS excerpt_len FROM outreach_items WHERE id BETWEEN 2263 AND 2277 ORDER BY id;'\""
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT id, variant, status FROM drafts WHERE outreach_item_id IN (2258, 2268) ORDER BY outreach_item_id, id;'\""

# After user OKs, the planned writes:
# 1. Archive thin-excerpt rows that pre-date the Followup 11 fix
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"UPDATE outreach_items SET status='archived' WHERE id BETWEEN 2263 AND 2277 AND status='drafting' AND (source_excerpt IS NULL OR LENGTH(source_excerpt) < 50) RETURNING id, status;\\\"\""
# 2. Reject the useless drafts on #2268 + close the item
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"UPDATE drafts SET status='rejected' WHERE outreach_item_id=2268 AND status='needs_human_review' RETURNING id, status;\\\"\""
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"UPDATE outreach_items SET status='reviewed' WHERE id=2268;\\\"\""
```

**Do NOT touch:** #2258 (3 good Joanna Penn / Nadim Sadek drafts in `needs_human_review` — user should approve via Slack now that buttons work) or #2259-2262 (good 1000-char excerpts still flowing through the drafter).

### (b) Verify Hash proper fix (task #128)

Followup 11's `code-node-return-shape-audit.js` grandfathers Workflow D's `publish-dispatcher.json:Verify Hash` with an inline citation. T25 row 62 SUCCESS suggests n8n tolerates the array-wrap pattern in some upstream-node shapes, but the grandfather is a known smell. Task #128 covers:
- Pre-deploy gate (0 `ready` rows in publish_jobs before cutover, same as B4).
- Synthetic publish_job smoke through the entire dispatcher path to prove the new shape works end-to-end (Bluesky test post that gets manually deleted, same shape as B7).
- Removal of the grandfather entry from `code-node-return-shape-audit.js` once the pattern is proven and Workflow D's node is migrated.

This is the only remaining audit grandfather. Phase 2 T30 can still tag without it (T30's gates are unchanged) but addressing it before tag is the cleaner path.

### (c) Phase 1 operational validation (user-driven, in progress)

Use the system for ≥1 week, process ≥10 real outreach items end-to-end. Now that dedup + thin-skip work, the noise floor is fixed and the drafter only sees items with real excerpts. Once 10 real items are approved + dispatched, tag Phase 1: `git tag -a outreach-phase1-shipped -m "Phase 1: approval gate end-to-end"`. This unblocks T30.

While the user is doing this, **do not deploy workflow changes** unless they explicitly confirm — n8n restart interrupts their session.

### (d) Phase 2 T30 (tag)

After (c) completes AND ≥5 production posts in `sent_to_postiz` (currently 1 — row 62 from T25) AND ArgoCD `temporal` + `postiz` Applications stay Synced/Healthy for a full 24h window:
```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT COUNT(*) FROM publish_jobs WHERE status = '\\''sent_to_postiz'\\'';'\""
ssh root@192.168.1.52 "kubectl get applications -n argocd temporal postiz"
```
Then `gh pr merge 18 --squash` (no `--delete-branch`; auto-cleanup handles it). Switch `apps/temporal/argocd-application.yaml` + `apps/postiz/argocd-application.yaml` `targetRevision` from `outreach/phase0-phase1` to `main`/`HEAD`. Then `git tag -a outreach-phase2-shipped -m "Phase 2: Postiz + Temporal + Workflow D"`.

### (e) Channel onboarding (user-gated)

- **Reddit Devvit revisit** if Reddit relaxes the Responsible Builder Policy.
- **LinkedIn** when Marketing Developer Platform approval comes through.
- **X — deferred indefinitely** (user-confirmed 2026-05-21 due to $100/mo Basic plan cost). Root cause + wiring instructions in `docs/runbooks/postiz-channel-onboarding.md` "### X" section.

## Resume procedure (next steps in order)

### 0. Read first

Before touching anything, read this entire file. The "User context" header note at the top is load-bearing: **Jeremy is actively using n8n for Phase 1 operational validation**. Do not re-import workflows, restart `n8n.service`, or otherwise interrupt LXC 112 without explicit confirmation in this session. Read-only DB queries via `pct exec 114` and read-only k8s queries are fine.

If you need to verify state before doing anything else:
```bash
# CI status on the open PR
gh pr view 18 --json statusCheckRollup --jq '.statusCheckRollup[] | {name, conclusion}'
# Recent commits on the branch
git log --oneline main..HEAD | head -15
# Live publish_jobs state (read-only)
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT id, status, destination_platform, destination_account, created_at FROM publish_jobs ORDER BY id DESC LIMIT 10;'\""
```

### 1. Confirm Followup 11 cleanup ran (TOP PRIORITY)

See "Top priority next session" section above — the planned thin-excerpt archive (2263-2277) + #2268 draft rejection were left pending user authorization in chat. Verify state first, run only with user OK. The dedup row `outcomes` id 30 at 16:22:38 UTC confirms Followup 11 fixed both prior-handoff Issue A and Issue B, but the data left over from before the fix needs the explicit cleanup.

### 2. Verify Hash proper fix (task #128)

Workflow D's `publish-dispatcher.json:Verify Hash` is the lone grandfathered entry in Followup 11's `code-node-return-shape-audit.js`. Plan a pre-deploy gate (0 `ready` rows, same as B4) + a synthetic publish_job smoke through the dispatcher (same shape as B7) + removal of the grandfather entry. Not blocking for Phase 2 T30 but addresses the only remaining audit smell.

### 3. Phase 1 operational validation (user-driven, in progress)

Use the system for ≥1 week, process ≥10 real outreach items end-to-end. Once done, tag Phase 1: `git tag -a outreach-phase1-shipped -m "Phase 1: approval gate end-to-end"`. This unblocks T30.

While the user is doing this, **do not deploy workflow changes** unless they explicitly confirm — n8n restart interrupts their session.

### 4. Phase 2 T30 (tag)

After step 3 completes AND ≥5 production posts in `sent_to_postiz` (currently 1 — row 62 from T25) AND ArgoCD `temporal` + `postiz` Applications stay Synced/Healthy for a full 24h window:
```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT COUNT(*) FROM publish_jobs WHERE status = '\\''sent_to_postiz'\\'';'\""
ssh root@192.168.1.52 "kubectl get applications -n argocd temporal postiz"
```
Then `gh pr merge 18 --squash` (no `--delete-branch`; auto-cleanup handles it). Switch `apps/temporal/argocd-application.yaml` + `apps/postiz/argocd-application.yaml` `targetRevision` from `outreach/phase0-phase1` to `main`/`HEAD`. Then `git tag -a outreach-phase2-shipped -m "Phase 2: Postiz + Temporal + Workflow D"`.

### 5. Channel onboarding (user-gated)

- **Reddit Devvit revisit** if Reddit relaxes the Responsible Builder Policy.
- **LinkedIn** when Marketing Developer Platform approval comes through.
- **X — deferred indefinitely** (user-confirmed 2026-05-21 due to $100/mo Basic plan cost). Root cause + wiring instructions in `docs/runbooks/postiz-channel-onboarding.md` "### X" section.

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

### 1. ~~publish_jobs.destination_account is empty after Workflow C writes it~~ ✅ FIXED commit `26fc6b7` + Phase 2.1 split

Workflow C's `pj` CTE in `Write Approval (CTE)` initially set both `destination_platform` and `destination_account` to `ins.approved_destination` (commit `26fc6b7`). Phase 2.1 then split that further (commit `87056b4` / B5): `destination_platform` now carries the semantic platform string (`bluesky`/`mastodon`/etc) and `destination_account` carries the Postiz integration ID. Workflow D's Postiz HTTP node reads `destination_account` as `integration.id` and is unchanged.

Slack quick-approve was historically a sibling `Write Slack Approval (CTE)` with no `pj` insert — that gap is also closed (commit `e205db1`); see known-issue #1 followups: Slack dispatch is gated on `decision='approved' AND length(approved_destination) > 0` so empty-destination drafts still record an approval but don't enqueue. The form `pj` shape was simplified again in commit `7122e4a` (unified dropdown — each form option maps directly to an integration ID).

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

### 6. X (Twitter) deferred indefinitely; LinkedIn pending approval

**X:** user-confirmed defer 2026-05-21. Root cause of "Could not connect to the platform" diagnosed in detail (missing `X_API_KEY`/`X_API_SECRET`; Postiz backend's `try/catch` at `apps/backend/src/api/routes/integrations.controller.ts:225-245` swallows the TwitterApi auth error and returns `{err:true}`). X requires a $100/mo Basic plan for posting since Feb 2023 — free tier is read-only. Full wiring instructions in `docs/runbooks/postiz-channel-onboarding.md` "### X" section if we ever revisit.

**LinkedIn:** blocked on Marketing Developer Platform approval (1-2 weeks typical). Phase 2 ships when 5 posts hit Bluesky + Mastodon.

### 7. Mastodon required env-var wiring + granular scopes

Postiz's standard mastodon provider uses `MASTODON_CLIENT_ID/SECRET/URL` env vars (wired in commit `5814fa5`). Mastodon app scopes must be granular (`write:statuses`, `write:media`, `profile`), NOT the broad `read write` checkbox. Documented in `docs/runbooks/postiz-channel-onboarding.md`.

### 8. ~~publish_jobs leftover stale rows~~ ✅ ROW 47 ABANDONED commit `f2ae505`

Row 47 (pre-CTE-fix legacy with hash-mismatch from the `>>>` mod-32 bug) is now `status='abandoned'`. Migration `20260521120000_publish_jobs_add_abandoned_status.sql` added `'abandoned'` to the publish_jobs.status CHECK so future operator-driven retirements are also reachable. Row 62 (T25 SUCCESS) remains as the only legitimate Phase 2 production row.

### 9. Phase 1 unmerged + not operationally validated (in progress)

`outreach/phase0-phase1` branch contains 99 commits — Phase 1 + Phase 2 + Phase 2.1 + 3 followups, all mixed. Phase 2 exit criterion 9 says "tag Phase 2 only after Phase 1 is tagged" — which itself requires 10 real items processed end-to-end (Jeremy's actual usage of the system over a week). **Jeremy started active n8n usage 2026-05-21**; treat live workflows as in-use until he reports back. Once 10 real items have been approved + dispatched, tag `outreach-phase1-shipped` to unblock T30.

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

All Phase 1 memories still apply. Phase 2 + Phase 2.1 + followups added:
- `n8n-crypto-require-blocked` — `require('crypto')` is blocked in n8n 2.9.4 Code nodes; use pure-JS SHA-256.
- `postiz-public-api-conventions` — base path `/api/public/v1/`, raw Authorization key (no Bearer), CreatePostDto shape.
- `n8n-credential-direct-db-edit` — CryptoJS AES (openssl-compatible) for headless credential fixes.
- `postgres-exporter-custom-query-prefix` — `--extend.query-path` metrics emit `{namespace}_{column}` verbatim (no `pg_` prefix); `--disable-default-metrics` doesn't silence all collectors (need `--no-collector.NAME`).
- `js-unsigned-rshift-modulo-32` — JS `>>>` takes shift amount mod 32; `x >>> 56` is `x >>> 24`. Use hardcoded 0s for high bytes in SHA-256 padding.
- `n8n-continueErrorOutput-routes-main1` — error path lives in `main[1]`, not a separate `"error"` connection key.
- `lxc-114-credential-less-psql` — `ssh cortech "pct exec 114 -- su - postgres -c psql ..."` lets you run superuser SQL without pulling an admin DB URL into the transcript (classifier-safe escape hatch).
- `postiz-err-true-swallows-integration-errors` — Postiz's `/api/integrations/social/:integration` GET handler catches all errors and returns `200 OK` with `{err:true}` (no log, no toast detail). Read the provider source under `/app/libraries/...` for the actual cause.

Still worth saving in future sessions (not done yet):
- "Postiz Mastodon needs env vars + granular scopes" — currently only in the channel-onboarding runbook.
- "Reddit Responsible Builder Policy blocks new OAuth apps as of late 2024" — deferral context.

## Recent commits (last 15 on branch — `git log --oneline main..HEAD | head -15`)

```
d7cd71c455688cda3cc5ca49d8d78fe8a42bcb9c feat(outreach): assert return-shape + RSS excerpt fallback + 2 CI guards
9f5a5ea docs(handoff): RSS expansion + follow.it + soft-block deployed
13de101 fix(outreach): restore discover.json indent shape after JSON round-trip
6473b1c fix(outreach): tighten r/writing soft-block to word boundary
e1a0219 fix(outreach): widen annerallen soft-block regex to match scheme://host shape
8b22ccf feat(outreach): expand RSS feeds, unwrap follow.it, soft-block list, backfill + CI guard
7b30e8f docs(handoff): Slack signature + parser hardening deployed
7ad32a9 fix(outreach): HMAC Slack signature over rawBody bytes, not re-encoded form
5b0abca docs(handoff): Slack blocksUi + form dedup fix deployed; 8 followups now
5c283ec test(outreach): add blocksUi shape drift guard for Slack nodes
43b3251 fix(outreach): wrap Slack blocksUi in object + dedupe approval-form integrations
3f2eb1c docs(handoff): smoke fix deployed; Phase 2.1 followups now 7
dba7ace test(outreach): minor cleanups + no-public-self-loop drift guard
d92ae02 fix(workflow-smoke): use 127.0.0.1:5678 self-loop + error-output Slack alert
fd49eba docs(handoff): Slack platform-picker deployed + CI drift guards landed
```

(100+ commits total on the branch — `git log --oneline main..HEAD` for the full list.)

## TODOs for next session

In priority order:

1. **Confirm Followup 11 cleanup** — Issues A & B from prior handoff are RESOLVED by Followup 11 (commit `d7cd71c455688cda3cc5ca49d8d78fe8a42bcb9c`, deployed 2026-05-22 16:22 UTC), but the data left behind needs explicit user authorization to clean up. Planned: archive thin-excerpt items 2263-2277 (15 rows), reject useless drafts on #2268 + close item, leave #2258 (good drafts) + #2259-2262 (good excerpts) alone. See "Top priority next session" section above for exact SQL.

2. **Verify Hash proper fix** (task #128) — Workflow D's `publish-dispatcher.json:Verify Hash` is grandfathered in the new `code-node-return-shape-audit.js`. Plan covers pre-deploy gate + synthetic publish_job smoke + grandfather removal. Not blocking T30 but the only remaining audit smell.

3. **Phase 1 operational validation** — ≥10 real items / ≥1 week of real usage; then tag `outreach-phase1-shipped`. Only step blocking Phase 2 tag. Dedup + thin-skip are now live so the noise floor is fixed.

4. **Phase 2 T30** — after #3 done + ≥5 production posts in `sent_to_postiz` (currently 1 — row 62 from T25) + 24h ArgoCD `temporal` + `postiz` Synced/Healthy window. Then `gh pr merge 18 --squash` and flip ArgoCD `targetRevision` from `outreach/phase0-phase1` to `main`/`HEAD`.

5. **Reddit / LinkedIn channel onboarding** when their gating clears. **X is deferred indefinitely** (paid plan cost — see "Phase 2.1 follow-ups" above for full diagnosis).

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
