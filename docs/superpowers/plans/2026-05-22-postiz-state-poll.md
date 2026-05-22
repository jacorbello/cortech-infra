# Postiz-State Poll Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, deploy, and prove a new n8n workflow `outreach-publish-poll` that closes the `publish_jobs.sent_to_postiz` vs actually-published honesty gap by polling Postiz `Post.state` every 2 minutes and reconciling `publish_jobs` + `outreach_items` to match reality.

**Architecture:** A new schedule-triggered (every 2 min) n8n workflow at `apps/outreach-workflows/n8n/poll.json` (id `pOlLpUbLiShReS01`) is built via a Python generator script under `scripts/n8n/build-poll-workflow.py` (reproducible, easier to review). The workflow lists Postiz posts via a single bounded `GET /api/public/v1/posts?startDate=&endDate=` call per cycle, then a `Reconcile` Code node emits per-row action records (`PUBLISH`/`FAIL_ERROR`/`FAIL_ORPHAN`/`STUCK`/`WARN_UNKNOWN`/`NOOP`) routed by a Switch to consolidated CTE-based Postgres nodes that atomically update `publish_jobs` + `outreach_items` + insert a `kind`-tagged row into `outcomes`. Workflow D loses its premature `outreach_items.status='published'` write (the `Rollup outreach_items` node + 3 connection edges are deleted). Four new CI drift guards plus a sandboxed state-machine test pin the design against silent regression; two schema tests pin the Mark Published CTE's idempotence and no-demote guards.

**Tech Stack:** n8n 2.9.4 self-hosted on LXC 112; PostgreSQL 16 on LXC 114 (192.168.1.83); Postiz public API at `https://postiz.corbello.io/api/public/v1` (raw key Auth, no `Bearer` prefix per memory `postiz-public-api-conventions`); existing `outreach-bot` Slack token in n8n credential `slack-bot-token`.

**Branch:** Continue on `outreach/phase0-phase1` (open PR #18). Stacked on `1a89145` (the spec commit). No worktree needed.

**Spec:** `docs/superpowers/specs/2026-05-22-postiz-state-poll-design.md` (commit `1a89145`).

**Why this is gated:**

- Jeremy is actively using LXC 112 n8n for Phase 1 operational validation. **`n8n.service` restart needs per-event typed-chat consent from the user** — the auto-mode classifier blocks `AskUserQuestion` answers for n8n restarts, so the consent must arrive as free-text in chat.
- Workflow D's Rollup-deletion edit + new workflow import + reactivation + service restart are a single deploy event. Pre-deploy gate: 0 `ready` publish_jobs rows (race-window check).
- No production DB writes outside the `pct exec 114 -- su - postgres -c psql ...` classifier-safe path (memory `lxc-114-credential-less-psql`).

**NO AI ATTRIBUTIONS in any commit message or PR.**

---

## File Structure

**Created:**
- `apps/outreach-workflows/n8n/poll.json` — new n8n workflow (generated from build script)
- `scripts/n8n/build-poll-workflow.py` — reproducible generator for `poll.json` (Python literal → JSON)
- `apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js` — CI drift guard
- `apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js` — CI drift guard
- `apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js` — CI drift guard
- `apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js` — CI sandbox test
- `apps/outreach-schema/db/tests/poll_mark_published_test.sql.sh` — schema test (idempotence + no-demote)

**Modified:**
- `apps/outreach-workflows/n8n/publish-dispatcher.json` — delete `Rollup outreach_items` node + remove 3 connection edges (from `Mark Sent`, `Mark Failed`, `Mark Manual`)
- `.github/workflows/outreach-ci.yml` — wire 4 new audit/test scripts into the `sha256-audit` job
- `apps/outreach-schema/db/tests/run_tests.sh` — source the new schema test
- `HANDOFF.md` — mark Postiz-state poll DEPLOYED, refresh next-priority list, update production-post count semantics

**On the live system (not in git):**
- LXC 112 `/root/poll.json` + `/root/publish-dispatcher.json` (intermediate copies for `n8n import:workflow`)
- LXC 112 n8n DB — import + activate `pOlLpUbLiShReS01`; re-import the edited `pUbLiShDiSpAtCh01`
- LXC 112 systemd — `systemctl restart n8n.service` (per-event consent required)
- LXC 114 — synthetic smoke row in `publish_jobs` (cleaned up at end of Task 12)

**Restore points:**
- `/tmp/pub-disp-before.json` + `/tmp/poll-before.json` on cortech master (snapshots from `n8n export:workflow` before any change; poll snapshot is the empty-state baseline)
- Repo `outreach/phase0-phase1` HEAD before this plan's first commit (recoverable via `git checkout <sha> -- <path>`)

---

## Task 1: Pre-flight verification

**Files:** none modified; read-only checks only.

- [ ] **Step 1: Confirm user has authorized this plan's deploy steps in chat**

  Tasks 11–12 require explicit typed-chat consent from Jeremy for the `n8n.service` restart. Do NOT proceed past Task 10 without it. Tasks 1–10 are repo-only edits + CI; safe to execute without restart consent.

- [ ] **Step 2: Confirm 0 `ready` publish_jobs rows (first race-window check)**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT
    COUNT(*) FILTER (WHERE status='ready')          AS ready_count,
    COUNT(*) FILTER (WHERE status='sent_to_postiz') AS sent_count,
    COUNT(*) FILTER (WHERE status='published')      AS published_count
  FROM publish_jobs;\\\"\""
  ```

  Expected: `ready_count = 0`, `sent_count >= 1` (row 62 from T25), `published_count = 0` (the published status has never been used yet).

  If `ready_count > 0`, STOP. Wait for the dispatcher's next 2-min cycle to drain them, or escalate. The pre-deploy gate at Task 10 re-checks this with stricter timing.

- [ ] **Step 3: Confirm sha256-audit baseline pass count**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/audit.js 2>&1 | tail -3
  ```

  Expected: `37 passed` (or higher if the count has grown since the HANDOFF was written). Note the exact number here for the post-deploy comparison.

- [ ] **Step 4: Confirm Workflow D still has the Rollup outreach_items node + its 3 inbound connection edges**

  ```bash
  python3 -c "
  import json
  d = json.load(open('apps/outreach-workflows/n8n/publish-dispatcher.json'))
  doc = (d if isinstance(d, list) else [d])[0]
  names = [n['name'] for n in doc['nodes']]
  print('Rollup outreach_items present:', 'Rollup outreach_items' in names)
  for src in ('Mark Sent', 'Mark Failed', 'Mark Manual'):
      out = doc['connections'].get(src, {}).get('main', [[]])[0]
      targets = [c['node'] for c in out] if out else []
      print(f'{src} -> Rollup:', 'Rollup outreach_items' in targets)
  "
  ```

  Expected output (4 lines, all `True`):
  ```
  Rollup outreach_items present: True
  Mark Sent -> Rollup: True
  Mark Failed -> Rollup: True
  Mark Manual -> Rollup: True
  ```

  If any line says `False`, STOP. The Workflow D file has drifted from the spec's assumptions. Re-read the spec and adjust the plan.

- [ ] **Step 5: Confirm Postiz live API still returns the expected shape**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 \"pct exec 112 -- bash -c 'PKEY=\\\$(systemctl show n8n.service -p Environment | tr \\\" \\\" \\\"\\\\n\\\" | sed -n \\\"s/^POSTIZ_API_KEY=//p\\\"); curl -sS -H \\\"Authorization: \\\$PKEY\\\" \\\"https://postiz.corbello.io/api/public/v1/posts?startDate=2026-05-19T00:00:00Z&endDate=2026-05-22T23:59:59Z\\\" | python3 -c \\\"import sys,json; d=json.load(sys.stdin); p=[x for x in d[\\\\\\\"posts\\\\\\\"] if x[\\\\\\\"id\\\\\\\"]==\\\\\\\"cmpel07680002j0au2phuim4q\\\\\\\"]; print(\\\\\\\"row62 found:\\\\\\\", bool(p)); print(\\\\\\\"state:\\\\\\\", p[0][\\\\\\\"state\\\\\\\"] if p else None); print(\\\\\\\"publishDate:\\\\\\\", p[0][\\\\\\\"publishDate\\\\\\\"] if p else None); print(\\\\\\\"releaseURL:\\\\\\\", p[0][\\\\\\\"releaseURL\\\\\\\"] if p else None)\\\"'\""
  ```

  Expected output:
  ```
  row62 found: True
  state: PUBLISHED
  publishDate: 2026-05-20T21:36:16.084Z
  releaseURL: https://bsky.app/profile/did:plc:p2jsluuydryaffoidrzdwaaj/post/3mmcuf2pela2g
  ```

  If `state != PUBLISHED`, STOP — the smoke test in Task 12 depends on this row's state being stable.

---

## Task 2: Edit Workflow D — delete Rollup node + 3 connection edges

**Files:**
- Modify: `apps/outreach-workflows/n8n/publish-dispatcher.json`

- [ ] **Step 1: Verify the current node count before edit**

  ```bash
  python3 -c "
  import json
  d = json.load(open('apps/outreach-workflows/n8n/publish-dispatcher.json'))
  doc = (d if isinstance(d, list) else [d])[0]
  print('node count:', len(doc['nodes']))
  print('connection sources:', len(doc['connections']))
  "
  ```

  Expected: `node count: 11`, `connection sources: 9` (approximate — record the actual values for the post-edit comparison).

- [ ] **Step 2: Delete the Rollup node and remove the 3 inbound connection edges**

  Run this Python edit script (writes back atomically):

  ```bash
  python3 <<'EOF'
  import json
  path = 'apps/outreach-workflows/n8n/publish-dispatcher.json'
  with open(path) as f:
      data = json.load(f)
  was_list = isinstance(data, list)
  docs = data if was_list else [data]
  doc = docs[0]

  # 1. Drop the Rollup node.
  before = len(doc['nodes'])
  doc['nodes'] = [n for n in doc['nodes'] if n['name'] != 'Rollup outreach_items']
  assert len(doc['nodes']) == before - 1, f"expected to delete exactly 1 node, deleted {before - len(doc['nodes'])}"

  # 2. Strip connection edges *into* Rollup outreach_items.
  for src, channels in list(doc['connections'].items()):
      new_main = []
      for branch in channels.get('main', []):
          new_main.append([edge for edge in branch if edge.get('node') != 'Rollup outreach_items'])
      channels['main'] = new_main

  # 3. Drop the Rollup key if it was a source itself (it wasn't, but defensive).
  doc['connections'].pop('Rollup outreach_items', None)

  with open(path, 'w') as f:
      json.dump(docs if was_list else doc, f)
  print('OK')
  EOF
  ```

  Expected output: `OK`. Any AssertionError means the file shape has drifted; STOP and re-investigate.

- [ ] **Step 3: Verify the edit (Rollup is gone + 3 source nodes no longer route to it)**

  ```bash
  python3 -c "
  import json
  d = json.load(open('apps/outreach-workflows/n8n/publish-dispatcher.json'))
  doc = (d if isinstance(d, list) else [d])[0]
  names = [n['name'] for n in doc['nodes']]
  print('Rollup outreach_items present:', 'Rollup outreach_items' in names)
  for src in ('Mark Sent', 'Mark Failed', 'Mark Manual'):
      out = doc['connections'].get(src, {}).get('main', [[]])[0]
      targets = [c['node'] for c in out] if out else []
      print(f'{src} -> Rollup:', 'Rollup outreach_items' in targets)
      print(f'{src} terminal:', len(targets) == 0)
  print('node count:', len(doc['nodes']))
  "
  ```

  Expected output (`Mark Sent`, `Mark Failed`, `Mark Manual` all terminal; node count `10`):
  ```
  Rollup outreach_items present: False
  Mark Sent -> Rollup: False
  Mark Sent terminal: True
  Mark Failed -> Rollup: False
  Mark Failed terminal: True
  Mark Manual -> Rollup: False
  Mark Manual terminal: True
  node count: 10
  ```

- [ ] **Step 4: Run existing CI guards locally — they MUST still pass**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/audit.js
  node apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  node apps/outreach-workflows/tests/sha256-audit/hash-payload-order.js
  ```

  Expected: each exits 0 with PASS. If any fails, STOP — Workflow D edit broke an existing invariant; revert with `git checkout HEAD -- apps/outreach-workflows/n8n/publish-dispatcher.json`.

- [ ] **Step 5: Commit**

  ```bash
  git add apps/outreach-workflows/n8n/publish-dispatcher.json
  git commit -m "fix(outreach): Workflow D no longer prematurely writes outreach_items.published

  The Rollup outreach_items node wrote outreach_items.status='published'
  on Postiz HTTP 200, before Postiz had actually confirmed publish to
  Bluesky/Mastodon. Row 72 (cleaned up via Followup 13) was the canonical
  proof: Postiz returned 200, our DB claimed published, Bluesky rejected
  the 542-grapheme text. Deletes the Rollup node and the 3 inbound edges
  from Mark Sent / Mark Failed / Mark Manual. The new outreach-publish-poll
  workflow (next commits) becomes the unique writer of outreach_items.published."
  ```

---

## Task 3: Author the new poll workflow via Python build script

**Files:**
- Create: `scripts/n8n/build-poll-workflow.py`
- Create: `apps/outreach-workflows/n8n/poll.json` (generated output)

- [ ] **Step 1: Create the build script**

  Create `scripts/n8n/build-poll-workflow.py` with this content (one tall block — paste verbatim):

  ```python
  #!/usr/bin/env python3
  # Generates apps/outreach-workflows/n8n/poll.json — the outreach-publish-poll workflow.
  #
  # Per docs/superpowers/specs/2026-05-22-postiz-state-poll-design.md. Run this whenever
  # the workflow shape needs an authoritative re-emit (e.g. after the n8n UI has been
  # used to edit and re-export). Output is byte-stable across runs given the same input.

  import json, os

  WORKFLOW_ID = "pOlLpUbLiShReS01"
  WORKFLOW_NAME = "outreach-publish-poll"

  CRED_POSTGRES = {"id": "fOZmso5kyXr6Agdn", "name": "outreach-db-n8n"}
  CRED_POSTIZ   = {"id": "pZtZApIkEy00000A", "name": "postiz-api-key"}
  CRED_SLACK    = {"id": "o9pysvcgZQFhoOLP", "name": "slack-bot-token"}

  SLACK_CHANNEL_ID = "C0B4SUTP8R4"  # SLACK_OUTREACH_CHANNEL_ID — see HANDOFF system-state table

  def node(id_, name, type_, type_version, position, parameters, credentials=None, on_error=None):
      n = {
          "parameters": parameters,
          "id": id_,
          "name": name,
          "type": type_,
          "typeVersion": type_version,
          "position": position,
      }
      if credentials:
          n["credentials"] = credentials
      if on_error:
          n["onError"] = on_error
      return n

  # ------- node definitions -------
  schedule_trigger = node(
      "po000001-0001-0000-0000-000000000001",
      "Schedule Trigger",
      "n8n-nodes-base.scheduleTrigger",
      1,
      [200, 300],
      {"rule": {"interval": [{"field": "minutes", "minutesInterval": 2}]}},
  )

  fetch_pending = node(
      "po000002-0001-0000-0000-000000000002",
      "Fetch Pending",
      "n8n-nodes-base.postgres",
      2.6,
      [420, 300],
      {
          "operation": "executeQuery",
          "query": (
              "SELECT pj.id AS publish_job_id, pj.postiz_post_id, pj.sent_at, "
              "EXTRACT(EPOCH FROM (now() - pj.sent_at)) AS age_seconds, "
              "(SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id = a.draft_id WHERE a.id = pj.approval_id) AS outreach_item_id "
              "FROM publish_jobs pj "
              "WHERE pj.status = 'sent_to_postiz' AND pj.published_at IS NULL "
              "ORDER BY pj.sent_at NULLS FIRST, pj.id;"
          ),
          "options": {},
      },
      credentials={"postgres": CRED_POSTGRES},
  )

  if_any_pending = node(
      "po000003-0001-0000-0000-000000000003",
      "Any Pending?",
      "n8n-nodes-base.if",
      2.2,
      [640, 300],
      {
          "conditions": {
              "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
              "conditions": [{
                  "id": "p1",
                  "leftValue": "={{ $json.publish_job_id }}",
                  "rightValue": "",
                  "operator": {"type": "string", "operation": "exists"},
              }],
              "combinator": "and",
          },
          "options": {},
      },
  )

  compute_window = node(
      "po000004-0001-0000-0000-000000000004",
      "Compute Window Bounds",
      "n8n-nodes-base.code",
      2,
      [860, 200],
      {
          "mode": "runOnceForAllItems",
          "jsCode": (
              "const rows = $input.all().map(i => i.json);\n"
              "const sentAts = rows.map(r => new Date(r.sent_at)).filter(d => !isNaN(d.getTime()));\n"
              "const minSent = sentAts.length ? new Date(Math.min(...sentAts.map(d => d.getTime()))) : new Date(Date.now() - 60*60*1000);\n"
              "const SLACK_MS = 5 * 60 * 1000;\n"
              "const startDate = new Date(minSent.getTime() - SLACK_MS).toISOString();\n"
              "const endDate = new Date(Date.now() + SLACK_MS).toISOString();\n"
              "return { json: { startDate, endDate, rows } };"
          ),
      },
  )

  postiz_list = node(
      "po000005-0001-0000-0000-000000000005",
      "Postiz List Posts",
      "n8n-nodes-base.httpRequest",
      4.2,
      [1080, 200],
      {
          "method": "GET",
          "url": "={{ $env.POSTIZ_API_BASE_URL }}/posts?startDate={{ encodeURIComponent($json.startDate) }}&endDate={{ encodeURIComponent($json.endDate) }}",
          "authentication": "predefinedCredentialType",
          "nodeCredentialType": "httpHeaderAuth",
          "options": {},
      },
      credentials={"httpHeaderAuth": CRED_POSTIZ},
      on_error="continueErrorOutput",
  )

  reconcile = node(
      "po000006-0001-0000-0000-000000000006",
      "Reconcile",
      "n8n-nodes-base.code",
      2,
      [1300, 200],
      {
          "mode": "runOnceForAllItems",
          "jsCode": (
              "// Build map: postiz_id -> { state, publishDate, releaseURL }\n"
              "const resp = $input.first().json;\n"
              "const posts = (resp && resp.posts) || [];\n"
              "const byId = new Map();\n"
              "for (const p of posts) byId.set(p.id, p);\n"
              "\n"
              "const STUCK_THRESHOLD_SECONDS = 30 * 60;\n"
              "const KNOWN_STATES = new Set(['PUBLISHED', 'QUEUE', 'ERROR']);\n"
              "\n"
              "const rows = $('Compute Window Bounds').item.json.rows || [];\n"
              "const out = [];\n"
              "for (const r of rows) {\n"
              "  const post = byId.get(r.postiz_post_id);\n"
              "  if (!post) {\n"
              "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'FAIL_ORPHAN', payload: {} } });\n"
              "    continue;\n"
              "  }\n"
              "  if (!KNOWN_STATES.has(post.state)) {\n"
              "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'WARN_UNKNOWN', payload: { state: post.state } } });\n"
              "    continue;\n"
              "  }\n"
              "  if (post.state === 'PUBLISHED') {\n"
              "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'PUBLISH', payload: { publish_date: post.publishDate, release_url: post.releaseURL || '' } } });\n"
              "    continue;\n"
              "  }\n"
              "  if (post.state === 'ERROR') {\n"
              "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'FAIL_ERROR', payload: {} } });\n"
              "    continue;\n"
              "  }\n"
              "  // QUEUE\n"
              "  if (Number(r.age_seconds) >= STUCK_THRESHOLD_SECONDS) {\n"
              "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'STUCK', payload: { age_seconds: Number(r.age_seconds) } } });\n"
              "  } else {\n"
              "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'NOOP', payload: {} } });\n"
              "  }\n"
              "}\n"
              "return out;"
          ),
      },
  )

  switch_action = node(
      "po000007-0001-0000-0000-000000000007",
      "Switch by Action",
      "n8n-nodes-base.switch",
      3,
      [1520, 300],
      {
          "rules": {
              "values": [
                  {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                   "conditions": [{"id": "a1", "leftValue": "={{ $json.action }}",
                                                   "rightValue": "PUBLISH",
                                                   "operator": {"type": "string", "operation": "equals"}}],
                                   "combinator": "and"},
                    "renameOutput": True, "outputKey": "publish"},
                  {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                   "conditions": [{"id": "a2", "leftValue": "={{ $json.action }}",
                                                   "rightValue": "FAIL_ERROR",
                                                   "operator": {"type": "string", "operation": "equals"}}],
                                   "combinator": "and"},
                    "renameOutput": True, "outputKey": "fail_error"},
                  {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                   "conditions": [{"id": "a3", "leftValue": "={{ $json.action }}",
                                                   "rightValue": "FAIL_ORPHAN",
                                                   "operator": {"type": "string", "operation": "equals"}}],
                                   "combinator": "and"},
                    "renameOutput": True, "outputKey": "fail_orphan"},
                  {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                   "conditions": [{"id": "a4", "leftValue": "={{ $json.action }}",
                                                   "rightValue": "STUCK",
                                                   "operator": {"type": "string", "operation": "equals"}}],
                                   "combinator": "and"},
                    "renameOutput": True, "outputKey": "stuck"},
                  {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                   "conditions": [{"id": "a5", "leftValue": "={{ $json.action }}",
                                                   "rightValue": "WARN_UNKNOWN",
                                                   "operator": {"type": "string", "operation": "equals"}}],
                                   "combinator": "and"},
                    "renameOutput": True, "outputKey": "warn_unknown"},
              ],
          },
          "options": {"fallbackOutput": "extra"},  # NOOP falls through to the unconnected extra output and ends
      },
  )

  mark_published = node(
      "po000008-0001-0000-0000-000000000008",
      "Mark Published & Log",
      "n8n-nodes-base.postgres",
      2.6,
      [1740, 100],
      {
          "operation": "executeQuery",
          "query": (
              "WITH pj_update AS ( "
              "  UPDATE publish_jobs "
              "     SET status='published', published_at=$1::timestamptz, published_url=$2 "
              "   WHERE id=$3 AND status='sent_to_postiz' AND published_at IS NULL "
              "  RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id "
              "), oi_update AS ( "
              "  UPDATE outreach_items SET status='published' "
              "   WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed' "
              "  RETURNING id "
              ") "
              "INSERT INTO outcomes (publish_job_id, notes) "
              "SELECT id, jsonb_build_object('kind','publish_confirmed','outreach_item_id',(SELECT outreach_item_id FROM pj_update),'postiz_post_id',$4,'published_at',$1,'published_url',$2)::text "
              "  FROM pj_update;"
          ),
          "options": {"queryReplacement": "={{ [$json.payload.publish_date, $json.payload.release_url, $json.publish_job_id, $json.postiz_post_id] }}"},
      },
      credentials={"postgres": CRED_POSTGRES},
  )

  mark_failed_error = node(
      "po000009-0001-0000-0000-000000000009",
      "Mark Failed (ERROR) & Log",
      "n8n-nodes-base.postgres",
      2.6,
      [1740, 220],
      {
          "operation": "executeQuery",
          "query": (
              "WITH pj_update AS ( "
              "  UPDATE publish_jobs SET status='failed', failure_reason='Postiz state=ERROR' "
              "   WHERE id=$1 AND status='sent_to_postiz' "
              "  RETURNING id "
              ") "
              "INSERT INTO outcomes (publish_job_id, notes) "
              "SELECT id, jsonb_build_object('kind','publish_failed','outreach_item_id',$2::bigint,'postiz_post_id',$3,'reason','postiz_error')::text "
              "  FROM pj_update;"
          ),
          "options": {"queryReplacement": "={{ [$json.publish_job_id, $json.outreach_item_id, $json.postiz_post_id] }}"},
      },
      credentials={"postgres": CRED_POSTGRES},
  )

  mark_failed_orphan = node(
      "po000010-0001-0000-0000-00000000000a",
      "Mark Failed (Orphan) & Log",
      "n8n-nodes-base.postgres",
      2.6,
      [1740, 340],
      {
          "operation": "executeQuery",
          "query": (
              "WITH pj_update AS ( "
              "  UPDATE publish_jobs SET status='failed', failure_reason='Postiz post not found' "
              "   WHERE id=$1 AND status='sent_to_postiz' "
              "  RETURNING id "
              ") "
              "INSERT INTO outcomes (publish_job_id, notes) "
              "SELECT id, jsonb_build_object('kind','publish_orphaned','outreach_item_id',$2::bigint,'postiz_post_id',$3,'reason','postiz_orphan')::text "
              "  FROM pj_update;"
          ),
          "options": {"queryReplacement": "={{ [$json.publish_job_id, $json.outreach_item_id, $json.postiz_post_id] }}"},
      },
      credentials={"postgres": CRED_POSTGRES},
  )

  mark_stuck = node(
      "po000011-0001-0000-0000-00000000000b",
      "Mark Manual (Stuck) & Log",
      "n8n-nodes-base.postgres",
      2.6,
      [1740, 460],
      {
          "operation": "executeQuery",
          "query": (
              "WITH pj_update AS ( "
              "  UPDATE publish_jobs SET status='manual_post_required', failure_reason='Stuck in Postiz QUEUE >30m' "
              "   WHERE id=$1 AND status='sent_to_postiz' "
              "  RETURNING id "
              ") "
              "INSERT INTO outcomes (publish_job_id, notes) "
              "SELECT id, jsonb_build_object('kind','publish_stuck','outreach_item_id',$2::bigint,'postiz_post_id',$3,'age_seconds',$4::int)::text "
              "  FROM pj_update;"
          ),
          "options": {"queryReplacement": "={{ [$json.publish_job_id, $json.outreach_item_id, $json.postiz_post_id, $json.payload.age_seconds] }}"},
      },
      credentials={"postgres": CRED_POSTGRES},
  )

  # Slack alerts — minimal text messages tagged with action kind.
  def slack_alert(id_, name, position, msg_template):
      return node(
          id_, name, "n8n-nodes-base.slack", 2.3, position,
          {
              "select": "channel",
              "channelId": {"__rl": True, "value": SLACK_CHANNEL_ID, "mode": "id"},
              "text": msg_template,
              "messageType": "text",
              "otherOptions": {},
          },
          credentials={"slackApi": CRED_SLACK},
      )

  slack_alert_failed = slack_alert(
      "po000012-0001-0000-0000-00000000000c",
      "Slack Alert Failed",
      [1960, 220],
      "={{ ':rotating_light: outreach-poll *publish_failed* — publish_job=' + $json.publish_job_id + ', outreach_item=' + $json.outreach_item_id + ', postiz_post=' + $json.postiz_post_id + '. Postiz Post.state=ERROR. Investigate Postiz logs.' }}",
  )
  slack_alert_orphan = slack_alert(
      "po000013-0001-0000-0000-00000000000d",
      "Slack Alert Orphaned",
      [1960, 340],
      "={{ ':rotating_light: outreach-poll *publish_orphaned* — publish_job=' + $json.publish_job_id + ', outreach_item=' + $json.outreach_item_id + ', postiz_post=' + $json.postiz_post_id + '. Postiz post not found in list (deleted via UI?).' }}",
  )
  slack_alert_stuck = slack_alert(
      "po000014-0001-0000-0000-00000000000e",
      "Slack Alert Stuck",
      [1960, 460],
      "={{ ':rotating_light: outreach-poll *publish_stuck* — publish_job=' + $json.publish_job_id + ', outreach_item=' + $json.outreach_item_id + ', postiz_post=' + $json.postiz_post_id + '. Stuck in Postiz QUEUE for ' + Math.floor(Number($json.payload.age_seconds)/60) + ' min.' }}",
  )
  slack_warn_unknown = slack_alert(
      "po000015-0001-0000-0000-00000000000f",
      "Slack Warning Unknown",
      [1740, 580],
      "={{ ':warning: outreach-poll *unknown_postiz_state* — publish_job=' + $json.publish_job_id + ', postiz_post=' + $json.postiz_post_id + ', state=`' + $json.payload.state + '`. Add handling to Reconcile.' }}",
  )

  slack_alert_http = slack_alert(
      "po000016-0001-0000-0000-000000000010",
      "Slack Alert Postiz HTTP",
      [1300, 460],
      "={{ ':rotating_light: outreach-poll *postiz_http_failure* — ' + (String($json.error || JSON.stringify($json)).slice(0, 400)) }}",
  )

  NODES = [
      schedule_trigger, fetch_pending, if_any_pending,
      compute_window, postiz_list, reconcile, switch_action,
      mark_published, mark_failed_error, mark_failed_orphan, mark_stuck,
      slack_alert_failed, slack_alert_orphan, slack_alert_stuck,
      slack_warn_unknown, slack_alert_http,
  ]

  CONNECTIONS = {
      "Schedule Trigger":      {"main": [[{"node": "Fetch Pending", "type": "main", "index": 0}]]},
      "Fetch Pending":         {"main": [[{"node": "Any Pending?", "type": "main", "index": 0}]]},
      "Any Pending?":          {"main": [[{"node": "Compute Window Bounds", "type": "main", "index": 0}], []]},
      "Compute Window Bounds": {"main": [[{"node": "Postiz List Posts", "type": "main", "index": 0}]]},
      "Postiz List Posts":     {"main": [[{"node": "Reconcile", "type": "main", "index": 0}], [{"node": "Slack Alert Postiz HTTP", "type": "main", "index": 0}]]},
      "Reconcile":             {"main": [[{"node": "Switch by Action", "type": "main", "index": 0}]]},
      "Switch by Action":      {"main": [
          [{"node": "Mark Published & Log", "type": "main", "index": 0}],
          [{"node": "Mark Failed (ERROR) & Log", "type": "main", "index": 0}],
          [{"node": "Mark Failed (Orphan) & Log", "type": "main", "index": 0}],
          [{"node": "Mark Manual (Stuck) & Log", "type": "main", "index": 0}],
          [{"node": "Slack Warning Unknown", "type": "main", "index": 0}],
      ]},
      "Mark Failed (ERROR) & Log":  {"main": [[{"node": "Slack Alert Failed", "type": "main", "index": 0}]]},
      "Mark Failed (Orphan) & Log": {"main": [[{"node": "Slack Alert Orphaned", "type": "main", "index": 0}]]},
      "Mark Manual (Stuck) & Log":  {"main": [[{"node": "Slack Alert Stuck", "type": "main", "index": 0}]]},
  }

  doc = {
      "id": WORKFLOW_ID,
      "name": WORKFLOW_NAME,
      "active": False,
      "isArchived": False,
      "nodes": NODES,
      "connections": CONNECTIONS,
      "settings": {"executionOrder": "v1"},
      "staticData": None,
      "meta": None,
      "pinData": None,
      "tags": [],
      "versionId": "",
      "triggerCount": 1,
  }

  out_path = "apps/outreach-workflows/n8n/poll.json"
  with open(out_path, "w") as f:
      json.dump([doc], f)
  print(f"wrote {out_path}, {len(NODES)} nodes, {len(CONNECTIONS)} connection sources")
  ```

- [ ] **Step 2: Make it executable and run it**

  ```bash
  chmod +x scripts/n8n/build-poll-workflow.py
  python3 scripts/n8n/build-poll-workflow.py
  ```

  Expected output: `wrote apps/outreach-workflows/n8n/poll.json, 16 nodes, 11 connection sources`.

- [ ] **Step 3: Sanity-check the generated workflow**

  ```bash
  python3 -c "
  import json
  d = json.load(open('apps/outreach-workflows/n8n/poll.json'))
  doc = (d if isinstance(d, list) else [d])[0]
  print('id:', doc['id'])
  print('name:', doc['name'])
  print('active:', doc['active'])
  print('node count:', len(doc['nodes']))
  names = [n['name'] for n in doc['nodes']]
  required = {'Schedule Trigger', 'Fetch Pending', 'Any Pending?', 'Compute Window Bounds',
              'Postiz List Posts', 'Reconcile', 'Switch by Action',
              'Mark Published & Log', 'Mark Failed (ERROR) & Log',
              'Mark Failed (Orphan) & Log', 'Mark Manual (Stuck) & Log',
              'Slack Alert Failed', 'Slack Alert Orphaned', 'Slack Alert Stuck',
              'Slack Warning Unknown', 'Slack Alert Postiz HTTP'}
  missing = required - set(names)
  print('missing nodes:', missing or 'none')
  # Confirm schedule is 2 min
  sched = next(n for n in doc['nodes'] if n['name']=='Schedule Trigger')
  print('schedule:', sched['parameters']['rule']['interval'][0])
  "
  ```

  Expected:
  ```
  id: pOlLpUbLiShReS01
  name: outreach-publish-poll
  active: False
  node count: 16
  missing nodes: none
  schedule: {'field': 'minutes', 'minutesInterval': 2}
  ```

- [ ] **Step 4: Run the existing CI guards locally — they MUST still pass**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/audit.js
  node apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  node apps/outreach-workflows/tests/sha256-audit/blocksui-shape-audit.js
  node apps/outreach-workflows/tests/sha256-audit/webhook-rawbody-audit.js
  ```

  Expected: each exits 0. The new poll workflow's Code nodes use `runOnceForAllItems` and return arrays — they should NOT trip the `code-node-return-shape-audit` guard (which only catches `runOnceForEachItem` array-wrap).

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/n8n/build-poll-workflow.py apps/outreach-workflows/n8n/poll.json
  git commit -m "feat(outreach): add outreach-publish-poll workflow (poll.json) + build script

  New n8n workflow that polls Postiz Post.state every 2 min and reconciles
  publish_jobs + outreach_items to reflect actual publish state. Source of
  truth for outreach_items.published. Generated via reproducible Python
  build script. Workflow NOT yet active or imported to LXC 112 — that's a
  separate user-consented deploy step."
  ```

---

## Task 4: Add `workflow-d-no-rollup-audit.js` drift guard

**Files:**
- Create: `apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js`
- Modify: `.github/workflows/outreach-ci.yml`

- [ ] **Step 1: Create the guard script**

  Create `apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js`:

  ```javascript
  #!/usr/bin/env node
  // Workflow D no-rollup drift guard.
  //
  // The original outreach-publish-dispatcher (Workflow D) wrote
  // outreach_items.status='published' via a Rollup outreach_items node fed
  // by Mark Sent, Mark Failed, and Mark Manual. That set the row to
  // "published" on Postiz HTTP 200 — before Postiz had actually published
  // to Bluesky/Mastodon. Row 72 (Followup 13) was the proof. The fix
  // (2026-05-22) was to delete the Rollup node and the 3 inbound edges.
  // The outreach-publish-poll workflow now owns the "published" write.
  //
  // This guard ensures the Rollup never returns.
  //
  // Pinned invariants:
  //   1. publish-dispatcher.json contains NO node named 'Rollup outreach_items'.
  //   2. NO Postgres node in publish-dispatcher.json's SQL string contains a
  //      write to outreach_items (UPDATE outreach_items ...).
  //
  // Re-run after editing publish-dispatcher.json:
  //   node apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js
  //
  // Exit code: 0 = invariants hold, 1 = drift.

  const fs = require('fs');
  const path = require('path');

  const REPO = path.resolve(__dirname, '../../../..');
  const D_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/publish-dispatcher.json');

  function main() {
      console.log('=== workflow-d-no-rollup drift guard ===');
      const raw = JSON.parse(fs.readFileSync(D_PATH, 'utf8'));
      const docs = Array.isArray(raw) ? raw : [raw];
      const failures = [];
      for (const doc of docs) {
          for (const node of (doc.nodes || [])) {
              if (node.name === 'Rollup outreach_items') {
                  failures.push("'Rollup outreach_items' node was reintroduced in publish-dispatcher.json");
              }
              if (node.type === 'n8n-nodes-base.postgres') {
                  const q = (node.parameters || {}).query || '';
                  if (/\bUPDATE\s+outreach_items\b/i.test(q) || /\bINSERT\s+INTO\s+outreach_items\b/i.test(q)) {
                      failures.push(`Postgres node '${node.name}' writes to outreach_items — the poll workflow is now the unique writer`);
                  }
              }
          }
      }

      if (failures.length === 0) {
          console.log('  OK: no Rollup node; no outreach_items writes in dispatcher');
          console.log('\nPASS: Workflow D no-rollup invariant intact.');
          process.exit(0);
      }
      console.error('\nFAIL: Workflow D drifted back toward premature outreach_items writes:');
      for (const f of failures) console.error(`  - ${f}`);
      process.exit(1);
  }

  main();
  ```

- [ ] **Step 2: Run it — should pass against the post-Task-2 state**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js
  ```

  Expected:
  ```
  === workflow-d-no-rollup drift guard ===
    OK: no Rollup node; no outreach_items writes in dispatcher

  PASS: Workflow D no-rollup invariant intact.
  ```

- [ ] **Step 3: Negative-test the guard (manual verification it actually catches drift)**

  Temporarily reintroduce a fake Rollup node:
  ```bash
  python3 <<'EOF'
  import json
  with open('apps/outreach-workflows/n8n/publish-dispatcher.json') as f:
      d = json.load(f)
  doc = (d if isinstance(d, list) else [d])[0]
  doc['nodes'].append({
      'parameters': {'operation': 'executeQuery', 'query': 'UPDATE outreach_items SET status=$1 WHERE id=$2;', 'options': {}},
      'id': 'rollback-test',
      'name': 'Rollup outreach_items',
      'type': 'n8n-nodes-base.postgres',
      'typeVersion': 2.6,
      'position': [9999, 9999],
  })
  with open('/tmp/dispatcher-drift.json', 'w') as f:
      json.dump([doc] if isinstance(d, list) else doc, f)
  EOF
  cp apps/outreach-workflows/n8n/publish-dispatcher.json /tmp/dispatcher-orig.json
  cp /tmp/dispatcher-drift.json apps/outreach-workflows/n8n/publish-dispatcher.json
  node apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js
  # Expected: exit code 1, FAIL printed
  cp /tmp/dispatcher-orig.json apps/outreach-workflows/n8n/publish-dispatcher.json
  rm /tmp/dispatcher-drift.json /tmp/dispatcher-orig.json
  ```

  Expected: the audit fails with both error lines (Rollup node + outreach_items write). After restoring, re-run the guard — should pass.

- [ ] **Step 4: Wire into `outreach-ci.yml` `sha256-audit` job**

  Open `.github/workflows/outreach-ci.yml`. Find the last step in the `sha256-audit` job (currently `Draft prompt invariants drift guard`). Append a new step:

  ```yaml
        - name: Workflow D no-rollup drift guard
          run: node apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js
  ```

  Use the existing 2-space indentation and the existing step shape.

- [ ] **Step 5: Commit**

  ```bash
  git add apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js .github/workflows/outreach-ci.yml
  git commit -m "test(outreach): CI guard rejects Rollup outreach_items in Workflow D

  Pins that publish-dispatcher.json contains no node named Rollup
  outreach_items and no Postgres node writes to outreach_items. After the
  outreach-publish-poll workflow takes over outreach_items.published, the
  dispatcher must never write that column again."
  ```

---

## Task 5: Add `poll-workflow-status-writes-audit.js` drift guard

**Files:**
- Create: `apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js`
- Modify: `.github/workflows/outreach-ci.yml`

- [ ] **Step 1: Create the guard script**

  Create `apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js`:

  ```javascript
  #!/usr/bin/env node
  // Poll workflow status-writes drift guard.
  //
  // outreach_items.status='published' is a terminal-truth statement: "this
  // item was actually published to the destination platform". The
  // outreach-publish-poll workflow (poll.json) is the unique writer of
  // that value — because it is the only workflow that has confirmation
  // from Postiz that the post landed.
  //
  // If any other workflow ever writes outreach_items.status='published'
  // (e.g. Workflow D regresses, or someone wires a new optimistic path),
  // this guard fails and forces the author to either route through the
  // poll or to explicitly justify the bypass.
  //
  // Pinned invariant:
  //   1. EXACTLY ONE workflow file under apps/outreach-workflows/n8n/
  //      contains a SQL string with outreach_items + status + 'published'
  //      in a write position. That file MUST be poll.json.
  //
  // Re-run after authoring any new workflow:
  //   node apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js
  //
  // Exit code: 0 = invariant holds, 1 = drift.

  const fs = require('fs');
  const path = require('path');

  const REPO = path.resolve(__dirname, '../../../..');
  const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

  function nodeQueryStrings(doc) {
      const queries = [];
      for (const node of (doc.nodes || [])) {
          if (node.type === 'n8n-nodes-base.postgres') {
              const q = ((node.parameters || {}).query || '').toString();
              if (q) queries.push({ nodeName: node.name, q });
          }
      }
      return queries;
  }

  function writesOutreachPublished(q) {
      // Heuristic: an UPDATE or INSERT that touches outreach_items AND mentions
      // status with the literal 'published'. Catches both forms:
      //   UPDATE outreach_items SET status='published' ...
      //   INSERT INTO outreach_items (... status ...) VALUES ('published' ...)
      const upper = q;
      const writesItems = /\b(UPDATE|INSERT\s+INTO)\s+outreach_items\b/i.test(upper);
      if (!writesItems) return false;
      // Must contain both 'status' and the literal 'published' inside the same statement.
      return /\bstatus\b/i.test(upper) && /'published'/.test(upper);
  }

  function main() {
      console.log('=== poll-workflow-status-writes drift guard ===');
      const files = fs.readdirSync(N8N_DIR).filter(f => f.endsWith('.json')).sort();
      const writers = [];
      for (const f of files) {
          const raw = JSON.parse(fs.readFileSync(path.join(N8N_DIR, f), 'utf8'));
          const docs = Array.isArray(raw) ? raw : [raw];
          for (const doc of docs) {
              for (const { nodeName, q } of nodeQueryStrings(doc)) {
                  if (writesOutreachPublished(q)) {
                      writers.push({ file: f, nodeName });
                  }
              }
          }
      }

      const failures = [];
      if (writers.length === 0) {
          failures.push("No workflow writes outreach_items.status='published'. Expected poll.json to do so.");
      } else {
          for (const w of writers) {
              if (w.file !== 'poll.json') {
                  failures.push(`'${w.file}' :: '${w.nodeName}' writes outreach_items.status='published' — poll.json must be the unique writer`);
              } else {
                  console.log(`  OK: '${w.file}' :: '${w.nodeName}' writes outreach_items.status='published'`);
              }
          }
      }

      if (failures.length === 0) {
          console.log('\nPASS: poll.json is the unique writer of outreach_items.published.');
          process.exit(0);
      }
      console.error('\nFAIL: outreach_items.status=\\'published\\' writes drifted:');
      for (const f of failures) console.error(`  - ${f}`);
      process.exit(1);
  }

  main();
  ```

- [ ] **Step 2: Run it — should pass after Tasks 2 + 3**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js
  ```

  Expected:
  ```
  === poll-workflow-status-writes drift guard ===
    OK: 'poll.json' :: 'Mark Published & Log' writes outreach_items.status='published'

  PASS: poll.json is the unique writer of outreach_items.published.
  ```

- [ ] **Step 3: Wire into `outreach-ci.yml`**

  Append after the previous task's step:

  ```yaml
        - name: Poll workflow status-writes drift guard
          run: node apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js .github/workflows/outreach-ci.yml
  git commit -m "test(outreach): CI guard pins poll.json as unique writer of outreach_items.published

  Any other workflow writing outreach_items.status='published' is treated
  as drift. The poll workflow is the only one with Postiz confirmation
  that the post actually landed."
  ```

---

## Task 6: Add `postiz-list-window-audit.js` drift guard

**Files:**
- Create: `apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js`
- Modify: `.github/workflows/outreach-ci.yml`

- [ ] **Step 1: Create the guard script**

  Create `apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js`:

  ```javascript
  #!/usr/bin/env node
  // Postiz list-window drift guard.
  //
  // Live probe (2026-05-22): GET /api/public/v1/posts returns HTTP 400
  // with {"message":["startDate must be a valid ISO 8601 date string",
  // "endDate must be a valid ISO 8601 date string"]} when called without
  // query params. Postiz mandates the date window. If poll.json ever
  // drops one of the params during a refactor, every poll cycle would
  // 400 and we'd silently lose state reconciliation.
  //
  // Pinned invariant:
  //   The 'Postiz List Posts' HTTP node in poll.json has a URL that
  //   contains BOTH 'startDate=' and 'endDate=' as substrings.
  //
  // Re-run after editing poll.json:
  //   node apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js
  //
  // Exit code: 0 = invariant holds, 1 = drift.

  const fs = require('fs');
  const path = require('path');

  const REPO = path.resolve(__dirname, '../../../..');
  const POLL_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/poll.json');

  function main() {
      console.log('=== postiz-list-window drift guard ===');
      const raw = JSON.parse(fs.readFileSync(POLL_PATH, 'utf8'));
      const docs = Array.isArray(raw) ? raw : [raw];
      const failures = [];
      let found = false;
      for (const doc of docs) {
          for (const node of (doc.nodes || [])) {
              if (node.name === 'Postiz List Posts' && node.type === 'n8n-nodes-base.httpRequest') {
                  found = true;
                  const url = (node.parameters || {}).url || '';
                  if (!url.includes('startDate=')) failures.push("'Postiz List Posts' URL missing 'startDate=' query param");
                  if (!url.includes('endDate=')) failures.push("'Postiz List Posts' URL missing 'endDate=' query param");
                  if (failures.length === 0) console.log(`  OK: URL = ${url}`);
              }
          }
      }
      if (!found) failures.push("'Postiz List Posts' HTTP node missing from poll.json");

      if (failures.length === 0) {
          console.log('\nPASS: Postiz list-window query params intact.');
          process.exit(0);
      }
      console.error('\nFAIL: Postiz list-window drift detected:');
      for (const f of failures) console.error(`  - ${f}`);
      process.exit(1);
  }

  main();
  ```

- [ ] **Step 2: Run it — should pass**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js
  ```

  Expected:
  ```
  === postiz-list-window drift guard ===
    OK: URL = ={{ $env.POSTIZ_API_BASE_URL }}/posts?startDate={{ encodeURIComponent($json.startDate) }}&endDate={{ encodeURIComponent($json.endDate) }}

  PASS: Postiz list-window query params intact.
  ```

- [ ] **Step 3: Wire into `outreach-ci.yml`**

  Append:

  ```yaml
        - name: Postiz list-window drift guard
          run: node apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js .github/workflows/outreach-ci.yml
  git commit -m "test(outreach): CI guard pins Postiz list-window startDate+endDate params

  GET /api/public/v1/posts returns HTTP 400 without both startDate and
  endDate. If poll.json's URL drifts to drop one of them, every poll
  cycle would silently 400 and state reconciliation would stop."
  ```

---

## Task 7: Add `poll-reconcile-state-machine.js` sandbox test

**Files:**
- Create: `apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js`
- Modify: `.github/workflows/outreach-ci.yml`

- [ ] **Step 1: Create the sandbox test**

  Create `apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js`:

  ```javascript
  #!/usr/bin/env node
  // Reconcile state-machine sandbox test.
  //
  // The Reconcile Code node in poll.json maps the Postiz GET /posts response
  // against the publish_jobs WHERE status='sent_to_postiz' set, emitting per-row
  // action records routed by the downstream Switch. The state machine is
  // load-bearing — every bug we've avoided in this design (premature published,
  // missed ERROR alerts, stuck queue silently inflating gauges) only avoids
  // regression as long as Reconcile keeps the mapping exact.
  //
  // This test VM-sandboxes the actual Reconcile jsCode against six input vectors
  // covering every row in the state table:
  //   1. found, state=PUBLISHED       -> action=PUBLISH (payload has publishDate + releaseURL)
  //   2. found, state=ERROR           -> action=FAIL_ERROR
  //   3. found, state=QUEUE, age<30m  -> action=NOOP
  //   4. found, state=QUEUE, age>=30m -> action=STUCK (payload.age_seconds set)
  //   5. not in Postiz list           -> action=FAIL_ORPHAN
  //   6. found, state=DRAFT (unknown) -> action=WARN_UNKNOWN
  //
  // Re-run after editing poll.json:
  //   node apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js
  //
  // Exit code: 0 = all vectors match expected action, 1 = drift.

  const fs = require('fs');
  const path = require('path');
  const vm = require('vm');

  const REPO = path.resolve(__dirname, '../../../..');
  const POLL_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/poll.json');

  function loadReconcileCode() {
      const raw = JSON.parse(fs.readFileSync(POLL_PATH, 'utf8'));
      const docs = Array.isArray(raw) ? raw : [raw];
      for (const doc of docs) {
          for (const node of (doc.nodes || [])) {
              if (node.name === 'Reconcile' && node.type === 'n8n-nodes-base.code') {
                  const code = (node.parameters || {}).jsCode;
                  if (typeof code !== 'string') throw new Error("'Reconcile' has no jsCode");
                  if (node.parameters.mode !== 'runOnceForAllItems') {
                      throw new Error("'Reconcile' must be mode=runOnceForAllItems");
                  }
                  return code;
              }
          }
      }
      throw new Error("'Reconcile' Code node not found in poll.json");
  }

  function runReconcile(code, postizPosts, rows) {
      // n8n provides $input, $() helpers, etc. We stub the minimal surface used by Reconcile.
      const sandbox = {
          $input: {
              first: () => ({ json: { posts: postizPosts } }),
              all:   () => [{ json: { posts: postizPosts } }],
          },
          $: (nodeName) => {
              if (nodeName === 'Compute Window Bounds') {
                  return { item: { json: { rows } } };
              }
              throw new Error(`Unstubbed $() reference: ${nodeName}`);
          },
          out: undefined,
      };
      // The Reconcile code returns a value (`return out;`). Wrap it in a function so
      // VM treats `return` as terminal.
      const wrapped = `out = (function() { ${code} })();`;
      vm.createContext(sandbox);
      vm.runInContext(wrapped, sandbox);
      return sandbox.out;
  }

  function eq(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

  function main() {
      console.log('=== poll-reconcile state-machine sandbox test ===');
      const code = loadReconcileCode();
      const failures = [];

      const POSTS = [
          { id: 'p_published', state: 'PUBLISHED', publishDate: '2026-05-22T10:00:00Z', releaseURL: 'https://bsky.app/...' },
          { id: 'p_error',     state: 'ERROR' },
          { id: 'p_queue_fresh', state: 'QUEUE' },
          { id: 'p_queue_stuck', state: 'QUEUE' },
          { id: 'p_unknown',   state: 'DRAFT' },
      ];
      const ROWS = [
          { publish_job_id: 1, outreach_item_id: 100, postiz_post_id: 'p_published',   sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
          { publish_job_id: 2, outreach_item_id: 101, postiz_post_id: 'p_error',       sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
          { publish_job_id: 3, outreach_item_id: 102, postiz_post_id: 'p_queue_fresh', sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
          { publish_job_id: 4, outreach_item_id: 103, postiz_post_id: 'p_queue_stuck', sent_at: '2026-05-22T09:25:00Z', age_seconds: 2100 },
          { publish_job_id: 5, outreach_item_id: 104, postiz_post_id: 'p_missing',     sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
          { publish_job_id: 6, outreach_item_id: 105, postiz_post_id: 'p_unknown',     sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
      ];

      const out = runReconcile(code, POSTS, ROWS);
      if (!Array.isArray(out) || out.length !== ROWS.length) {
          failures.push(`Reconcile returned ${out ? out.length : 'undefined'} items, expected ${ROWS.length}`);
      } else {
          const expected = [
              { action: 'PUBLISH',      pid: 'p_published',    extra: { publish_date: '2026-05-22T10:00:00Z', release_url: 'https://bsky.app/...' } },
              { action: 'FAIL_ERROR',   pid: 'p_error' },
              { action: 'NOOP',         pid: 'p_queue_fresh' },
              { action: 'STUCK',        pid: 'p_queue_stuck',  extra: { age_seconds: 2100 } },
              { action: 'FAIL_ORPHAN',  pid: 'p_missing' },
              { action: 'WARN_UNKNOWN', pid: 'p_unknown',      extra: { state: 'DRAFT' } },
          ];
          for (let i = 0; i < expected.length; i++) {
              const actual = out[i].json;
              const exp = expected[i];
              if (actual.action !== exp.action) {
                  failures.push(`Vector ${i+1} (${exp.pid}): expected action=${exp.action}, got ${actual.action}`);
              } else if (exp.extra) {
                  if (exp.action === 'PUBLISH' && (actual.payload.publish_date !== exp.extra.publish_date || actual.payload.release_url !== exp.extra.release_url)) {
                      failures.push(`Vector ${i+1} (${exp.pid}): payload mismatch: got ${JSON.stringify(actual.payload)}`);
                  } else if (exp.action === 'STUCK' && Number(actual.payload.age_seconds) !== exp.extra.age_seconds) {
                      failures.push(`Vector ${i+1} (${exp.pid}): age_seconds mismatch: got ${actual.payload.age_seconds}`);
                  } else if (exp.action === 'WARN_UNKNOWN' && actual.payload.state !== exp.extra.state) {
                      failures.push(`Vector ${i+1} (${exp.pid}): state mismatch: got ${actual.payload.state}`);
                  } else {
                      console.log(`  OK: vector ${i+1} (${exp.pid}) -> ${exp.action}`);
                  }
              } else {
                  console.log(`  OK: vector ${i+1} (${exp.pid}) -> ${exp.action}`);
              }
          }
      }

      if (failures.length === 0) {
          console.log('\nPASS: Reconcile state machine matches the 6-vector table.');
          process.exit(0);
      }
      console.error('\nFAIL: Reconcile state-machine drift:');
      for (const f of failures) console.error(`  - ${f}`);
      process.exit(1);
  }

  main();
  ```

- [ ] **Step 2: Run it — should pass**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js
  ```

  Expected:
  ```
  === poll-reconcile state-machine sandbox test ===
    OK: vector 1 (p_published) -> PUBLISH
    OK: vector 2 (p_error) -> FAIL_ERROR
    OK: vector 3 (p_queue_fresh) -> NOOP
    OK: vector 4 (p_queue_stuck) -> STUCK
    OK: vector 5 (p_missing) -> FAIL_ORPHAN
    OK: vector 6 (p_unknown) -> WARN_UNKNOWN

  PASS: Reconcile state machine matches the 6-vector table.
  ```

- [ ] **Step 3: Wire into `outreach-ci.yml`**

  Append:

  ```yaml
        - name: Poll reconcile state-machine sandbox test
          run: node apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js .github/workflows/outreach-ci.yml
  git commit -m "test(outreach): sandbox the Reconcile state machine against 6 vectors

  VM-sandboxes the actual Reconcile jsCode in poll.json and asserts every
  Postiz state -> action mapping (PUBLISHED, ERROR, QUEUE fresh, QUEUE
  stuck, not-found, unknown). Catches silent drift in the load-bearing
  state machine."
  ```

---

## Task 8: Add Mark Published CTE schema tests

**Files:**
- Create: `apps/outreach-schema/db/tests/poll_mark_published_test.sql.sh`
- Modify: `apps/outreach-schema/db/tests/run_tests.sh`

- [ ] **Step 1: Create the schema test**

  Create `apps/outreach-schema/db/tests/poll_mark_published_test.sql.sh`:

  ```bash
  # poll_mark_published_test.sql.sh — sourced from run_tests.sh.
  #
  # Pins the Mark Published CTE used by the outreach-publish-poll workflow:
  #   1. Idempotence: running the CTE twice on the same row mutates only once.
  #   2. No-demote: when outreach_items.status='rejected' (operator hand-rejected
  #      after the publish_job was dispatched), the CTE flips publish_jobs but
  #      MUST NOT promote outreach_items back to 'published'.

  echo ""
  echo "--- poll_mark_published_test.sql.sh ---"

  # Test 1: Idempotence. Run Mark Published twice on the same publish_jobs row.
  # The second run should be a no-op (UPDATE matches 0 rows; outcomes INSERT
  # matches 0 rows via the WHERE EXISTS / FROM pj_update guard).
  run_expect_pass "Mark Published CTE: idempotent on second invocation" "
      WITH oi AS (
        INSERT INTO outreach_items (source_platform, source_url, status)
        VALUES ('manual', 'https://example.com/idem-' || extract(epoch from now())::text, 'reviewed')
        RETURNING id
      ),
      dr AS (
        INSERT INTO drafts (outreach_item_id, variant, draft_text, status)
        SELECT id, 'helpful_only', 'idem test draft', 'approved' FROM oi
        RETURNING id
      ),
      ap AS (
        INSERT INTO approvals (draft_id, decision, approved_content_hash, approved_destination, approved_post_type, approved_platform, edited_text)
        SELECT id, 'approved', 'idem-hash', 'idem-dest', 'reply', 'bluesky', 'idem test draft' FROM dr
        RETURNING id
      ),
      pj AS (
        INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, status, postiz_post_id, sent_at, payload_hash)
        SELECT id, 'bluesky', 'idem-dest', 'postiz_immediate', 'sent_to_postiz', 'idem-postiz-id', now(), 'idem-hash' FROM ap
        RETURNING id
      )
      SELECT id INTO TEMP TABLE tmp_pj FROM pj;

      -- First invocation: mutates.
      WITH pj_update AS (
        UPDATE publish_jobs
           SET status='published', published_at=now(), published_url='https://bsky.app/idem'
         WHERE id=(SELECT id FROM tmp_pj) AND status='sent_to_postiz' AND published_at IS NULL
        RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id
      ), oi_update AS (
        UPDATE outreach_items SET status='published'
         WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed'
        RETURNING id
      )
      INSERT INTO outcomes (publish_job_id, notes)
      SELECT id, jsonb_build_object('kind','publish_confirmed')::text FROM pj_update;

      DO \$\$
      DECLARE r_pj_status TEXT; r_oi_status TEXT; r_outcomes INT;
      BEGIN
        SELECT status INTO r_pj_status FROM publish_jobs WHERE id = (SELECT id FROM tmp_pj);
        SELECT oi.status INTO r_oi_status FROM outreach_items oi
          JOIN drafts d ON d.outreach_item_id = oi.id
          JOIN approvals a ON a.draft_id = d.id
          JOIN publish_jobs pj ON pj.approval_id = a.id WHERE pj.id = (SELECT id FROM tmp_pj);
        SELECT COUNT(*) INTO r_outcomes FROM outcomes WHERE publish_job_id = (SELECT id FROM tmp_pj);
        IF r_pj_status <> 'published' THEN RAISE EXCEPTION 'pj status after run 1 = %', r_pj_status; END IF;
        IF r_oi_status <> 'published' THEN RAISE EXCEPTION 'oi status after run 1 = %', r_oi_status; END IF;
        IF r_outcomes <> 1 THEN RAISE EXCEPTION 'outcomes count after run 1 = %', r_outcomes; END IF;
      END
      \$\$;

      -- Second invocation: must be a no-op.
      WITH pj_update AS (
        UPDATE publish_jobs
           SET status='published', published_at=now(), published_url='https://bsky.app/idem2'
         WHERE id=(SELECT id FROM tmp_pj) AND status='sent_to_postiz' AND published_at IS NULL
        RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id
      ), oi_update AS (
        UPDATE outreach_items SET status='published'
         WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed'
        RETURNING id
      )
      INSERT INTO outcomes (publish_job_id, notes)
      SELECT id, jsonb_build_object('kind','publish_confirmed')::text FROM pj_update;

      DO \$\$
      DECLARE r_outcomes INT;
      BEGIN
        SELECT COUNT(*) INTO r_outcomes FROM outcomes WHERE publish_job_id = (SELECT id FROM tmp_pj);
        IF r_outcomes <> 1 THEN RAISE EXCEPTION 'outcomes count after run 2 = % (expected idempotent no-op)', r_outcomes; END IF;
      END
      \$\$;
  "

  # Test 2: No-demote. outreach_items.status='rejected' must remain 'rejected'
  # even though the CTE flips publish_jobs to 'published'.
  run_expect_pass "Mark Published CTE: never promotes outreach_items from rejected" "
      WITH oi AS (
        INSERT INTO outreach_items (source_platform, source_url, status)
        VALUES ('manual', 'https://example.com/reject-' || extract(epoch from now())::text, 'rejected')
        RETURNING id
      ),
      dr AS (
        INSERT INTO drafts (outreach_item_id, variant, draft_text, status)
        SELECT id, 'helpful_only', 'reject test draft', 'approved' FROM oi
        RETURNING id
      ),
      ap AS (
        INSERT INTO approvals (draft_id, decision, approved_content_hash, approved_destination, approved_post_type, approved_platform, edited_text)
        SELECT id, 'approved', 'reject-hash', 'reject-dest', 'reply', 'bluesky', 'reject test draft' FROM dr
        RETURNING id
      ),
      pj AS (
        INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, status, postiz_post_id, sent_at, payload_hash)
        SELECT id, 'bluesky', 'reject-dest', 'postiz_immediate', 'sent_to_postiz', 'reject-postiz-id', now(), 'reject-hash' FROM ap
        RETURNING id
      )
      SELECT id INTO TEMP TABLE tmp_pj_reject FROM pj;

      WITH pj_update AS (
        UPDATE publish_jobs
           SET status='published', published_at=now(), published_url='https://bsky.app/reject'
         WHERE id=(SELECT id FROM tmp_pj_reject) AND status='sent_to_postiz' AND published_at IS NULL
        RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id
      ), oi_update AS (
        UPDATE outreach_items SET status='published'
         WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed'
        RETURNING id
      )
      INSERT INTO outcomes (publish_job_id, notes)
      SELECT id, jsonb_build_object('kind','publish_confirmed')::text FROM pj_update;

      DO \$\$
      DECLARE r_pj_status TEXT; r_oi_status TEXT;
      BEGIN
        SELECT status INTO r_pj_status FROM publish_jobs WHERE id = (SELECT id FROM tmp_pj_reject);
        SELECT oi.status INTO r_oi_status FROM outreach_items oi
          JOIN drafts d ON d.outreach_item_id = oi.id
          JOIN approvals a ON a.draft_id = d.id
          JOIN publish_jobs pj ON pj.approval_id = a.id WHERE pj.id = (SELECT id FROM tmp_pj_reject);
        IF r_pj_status <> 'published' THEN RAISE EXCEPTION 'pj status = %', r_pj_status; END IF;
        IF r_oi_status <> 'rejected' THEN RAISE EXCEPTION 'oi was promoted from rejected to %', r_oi_status; END IF;
      END
      \$\$;
  "
  ```

- [ ] **Step 2: Source the new test file from `run_tests.sh`**

  Edit `apps/outreach-schema/db/tests/run_tests.sh` — find the line `source ./trigger_enforcement_test.sql.sh` near the bottom and add the new source line immediately after it:

  ```bash
  source ./trigger_enforcement_test.sql.sh
  source ./poll_mark_published_test.sql.sh
  ```

- [ ] **Step 3: Verify the schema test parses (locally)**

  If you have a local Postgres + `dbmate` set up like the CI job, run:

  ```bash
  cd apps/outreach-schema
  DATABASE_URL=<your-local-test-db-url> ./db/tests/run_tests.sh
  ```

  Expected: all trigger_enforcement tests PASS as before, plus 2 new PASS lines:
  ```
  PASS: Mark Published CTE: idempotent on second invocation
  PASS: Mark Published CTE: never promotes outreach_items from rejected
  All tests passed.
  ```

  If you don't have a local test DB, skip this step — the CI run in Task 9 will verify.

- [ ] **Step 4: Commit**

  ```bash
  git add apps/outreach-schema/db/tests/poll_mark_published_test.sql.sh apps/outreach-schema/db/tests/run_tests.sh
  git commit -m "test(outreach): schema tests for Mark Published CTE — idempotence + no-demote

  Two transaction-rollback tests pinning the load-bearing CTE used by the
  outreach-publish-poll workflow: (1) running it twice on the same row
  mutates only once, (2) outreach_items.status='rejected' is never
  promoted to 'published' even when the publish_jobs side flips."
  ```

---

## Task 9: Push branch + wait for CI green

**Files:** none.

- [ ] **Step 1: Push the branch**

  ```bash
  git push origin outreach/phase0-phase1
  ```

  Expected: fast-forward push from the prior HEAD (`1a89145` or later) to whatever HEAD is now (~6 commits added by this plan).

- [ ] **Step 2: Confirm PR #18 is still mergeable**

  ```bash
  gh pr view 18 --json mergeable,statusCheckRollup --jq '{mergeable, checks: [.statusCheckRollup[] | {name, conclusion}]}'
  ```

  Expected: `mergeable: MERGEABLE`, all check `conclusion` either `null` (still running) or `SUCCESS`.

- [ ] **Step 3: Wait for CI green**

  ```bash
  gh pr checks 18 --watch
  ```

  Expected: all 4 CI jobs (`schema`, `audit`, `sha256-audit`, `manifests-lint`) pass. The `schema` job now runs the 2 new Mark Published tests; the `sha256-audit` job now runs 4 new guards/tests.

  If anything fails, fix and amend the relevant task's commit (do NOT --amend the spec commit `1a89145`). Stop here and resolve before proceeding.

---

## Task 10: Pre-deploy gate (final 0-ready-rows check + restore-point snapshots)

**Files:** none in repo; produces `/tmp/pub-disp-before.json` + `/tmp/poll-before.json` on cortech master.

- [ ] **Step 1: Confirm 0 ready publish_jobs rows (tight race window check)**

  Run this twice, ~30 seconds apart. Both must show `ready_count = 0`. If either shows >0, wait for the dispatcher's next cycle and re-check.

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT
    COUNT(*) FILTER (WHERE status='ready')          AS ready_count,
    COUNT(*) FILTER (WHERE status='sent_to_postiz') AS sent_count
  FROM publish_jobs;\\\"\""
  ```

- [ ] **Step 2: Snapshot the live Workflow D export**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"n8n export:workflow --id=pUbLiShDiSpAtCh01 --output=/root/pub-disp-before.json && wc -c /root/pub-disp-before.json\"'"
  ```

  Expected: a positive byte count (~12 KB), no errors.

- [ ] **Step 3: Pull the snapshot to cortech master**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct pull 112 /root/pub-disp-before.json /tmp/pub-disp-before.json' && ls -la /tmp/pub-disp-before.json"
  ```

  Expected: file exists and has same byte count as the LXC 112 copy.

- [ ] **Step 4: Confirm there is no existing `pOlLpUbLiShReS01` workflow** (this is a new id; if it already exists we have a conflict)

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"n8n list:workflow | grep pOlLpUbLiShReS01 || echo MISSING_AS_EXPECTED\"'"
  ```

  Expected: `MISSING_AS_EXPECTED`. If the id already exists, STOP and rename the new workflow id before redeploying.

---

## Task 11: User-authorized deploy (BLOCKED ON CHAT CONSENT)

**Files:** none in repo.

**STOP. Do not proceed without typed-chat consent from the user.** AskUserQuestion answers are blocked by the auto-mode classifier for n8n restarts. The user must say something like "go ahead with the restart" in free-text chat.

- [ ] **Step 1: Wait for explicit chat consent**

  Once received, proceed.

- [ ] **Step 2: Push the new poll.json + edited dispatcher to LXC 112**

  ```bash
  ssh root@192.168.1.52 "scp /tmp/pub-disp-before.json root@192.168.1.80:/tmp/pub-disp-before-on-node5.json" || true
  # Push the EDITED dispatcher and the NEW poll workflow from the repo to LXC 112:
  scp apps/outreach-workflows/n8n/poll.json root@192.168.1.52:/tmp/poll.json
  scp apps/outreach-workflows/n8n/publish-dispatcher.json root@192.168.1.52:/tmp/publish-dispatcher.json
  ssh root@192.168.1.52 "scp /tmp/poll.json /tmp/publish-dispatcher.json root@192.168.1.80:/tmp/ && ssh root@192.168.1.80 'pct push 112 /tmp/poll.json /root/poll.json && pct push 112 /tmp/publish-dispatcher.json /root/publish-dispatcher.json'"
  ```

  Expected: no errors.

- [ ] **Step 3: Import both workflows into n8n DB**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"n8n import:workflow --input=/root/poll.json && n8n import:workflow --input=/root/publish-dispatcher.json\"'"
  ```

  Expected: 2 success lines.

- [ ] **Step 4: Activate the new poll workflow** (dispatcher was already active; the edit preserves that)

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"n8n update:workflow --id=pOlLpUbLiShReS01 --active=true\"'"
  ```

  Expected: success.

- [ ] **Step 5: Restart n8n.service**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"systemctl restart n8n.service && sleep 3 && systemctl is-active n8n.service\"'"
  ```

  Expected: `active`. If `failed`, check `journalctl -u n8n.service -n 100` immediately.

- [ ] **Step 6: Verify activation in journal**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"journalctl -u n8n.service -n 50 --no-pager | grep -E \\\"Activated workflow|outreach-publish-poll|outreach-publish-dispatcher\\\"\"'"
  ```

  Expected: at least one line containing `Activated workflow "outreach-publish-poll"` AND one for `outreach-publish-dispatcher`.

- [ ] **Step 7: Verify DB state**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"n8n list:workflow --onlyId | grep -E \\\"pOlLpUbLiShReS01|pUbLiShDiSpAtCh01\\\"\"'"
  ```

  Expected: both IDs appear.

---

## Task 12: Synthetic smoke + row 62 backfill capture

**Files:** none in repo; transient row in LXC 114 publish_jobs.

- [ ] **Step 1: Insert the synthetic publish_jobs row**

  The synthetic uses `postiz_post_id='cmpel07680002j0au2phuim4q'` — the same id as production row 62 (known `PUBLISHED` from Task 1 Step 5). This means the upcoming poll cycle will reconcile BOTH the synthetic and the legitimate row 62 in the same pass — that's intentional. We clean up the synthetic at the end; row 62 transitions legitimately.

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"
  WITH oi AS (
    INSERT INTO outreach_items (source_platform, source_url, status)
    VALUES ('manual', 'https://example.com/smoke-poll-' || extract(epoch from now())::text, 'reviewed')
    RETURNING id
  ),
  dr AS (
    INSERT INTO drafts (outreach_item_id, variant, draft_text, status)
    SELECT id, 'helpful_only', 'smoke test draft', 'approved' FROM oi RETURNING id
  ),
  ap AS (
    INSERT INTO approvals (draft_id, decision, approved_content_hash, approved_destination, approved_post_type, approved_platform, edited_text)
    SELECT id, 'approved', 'smoke-hash', 'smoke-dest', 'reply', 'bluesky', 'smoke test draft' FROM dr RETURNING id
  ),
  pj AS (
    INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, status, postiz_post_id, sent_at, payload_hash)
    SELECT id, 'bluesky', 'smoke-dest', 'postiz_immediate', 'sent_to_postiz', 'cmpel07680002j0au2phuim4q', now(), 'smoke-hash' FROM ap RETURNING id
  )
  SELECT id AS synthetic_publish_job_id FROM pj;
  \\\"\""
  ```

  Record the returned `synthetic_publish_job_id` (called `$SYN_ID` below).

- [ ] **Step 2: Verify the synthetic row + row 62 both currently at `sent_to_postiz`**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT id, status, postiz_post_id, published_at, sent_at FROM publish_jobs WHERE id IN (62, $SYN_ID) ORDER BY id;\\\"\""
  ```

  Expected: 2 rows, both `status=sent_to_postiz`, both `published_at IS NULL`, both `postiz_post_id='cmpel07680002j0au2phuim4q'`.

- [ ] **Step 3: Wait one poll cycle (~2 min)**

  ```bash
  sleep 150
  ```

- [ ] **Step 4: Verify both rows transitioned to `published`**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT id, status, published_at, published_url FROM publish_jobs WHERE id IN (62, $SYN_ID) ORDER BY id;\\\"\""
  ```

  Expected: both rows `status='published'`, both `published_at='2026-05-20 21:36:16.084+00'`, both `published_url='https://bsky.app/profile/did:plc:p2jsluuydryaffoidrzdwaaj/post/3mmcuf2pela2g'`.

  If either row is still `sent_to_postiz`, check journal for poll errors:
  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"journalctl -u n8n.service -n 100 --no-pager | grep -iE \\\"poll|error\\\"\"'"
  ```

- [ ] **Step 5: Verify outreach_items.published for row 62's item only**

  Row 62's `outreach_item_id` is in `drafts` table → look it up:

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT oi.id, oi.status FROM outreach_items oi JOIN drafts d ON d.outreach_item_id=oi.id JOIN approvals a ON a.draft_id=d.id JOIN publish_jobs pj ON pj.approval_id=a.id WHERE pj.id IN (62, $SYN_ID) ORDER BY pj.id;\\\"\""
  ```

  Expected: 2 rows. Row 62's item is `status='published'`. The synthetic row's item is `status='published'` too (because we INSERTed it at `'reviewed'`). Both are honest.

- [ ] **Step 6: Verify outcomes audit rows exist**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT id, publish_job_id, notes::jsonb->>'kind' AS kind, notes::jsonb->>'postiz_post_id' AS postiz_post_id, captured_at FROM outcomes WHERE publish_job_id IN (62, $SYN_ID) ORDER BY id DESC LIMIT 5;\\\"\""
  ```

  Expected: at least 2 rows with `kind='publish_confirmed'` and matching `postiz_post_id`.

- [ ] **Step 7: Clean up the synthetic publish_job + its synthetic outreach_item / draft / approval**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"
  WITH del_pj AS (DELETE FROM publish_jobs WHERE id=$SYN_ID RETURNING approval_id),
       del_o  AS (DELETE FROM outcomes WHERE publish_job_id=$SYN_ID RETURNING id),
       ap_id  AS (SELECT approval_id FROM del_pj),
       del_ap AS (DELETE FROM approvals WHERE id=(SELECT approval_id FROM ap_id) RETURNING draft_id),
       dr_id  AS (SELECT draft_id FROM del_ap),
       del_dr AS (DELETE FROM drafts WHERE id=(SELECT draft_id FROM dr_id) RETURNING outreach_item_id),
       oi_id  AS (SELECT outreach_item_id FROM del_dr),
       del_oi AS (DELETE FROM outreach_items WHERE id=(SELECT outreach_item_id FROM oi_id) RETURNING id)
  SELECT (SELECT COUNT(*) FROM del_pj) AS pj_deleted, (SELECT COUNT(*) FROM del_o) AS outcomes_deleted, (SELECT COUNT(*) FROM del_ap) AS ap_deleted, (SELECT COUNT(*) FROM del_dr) AS dr_deleted, (SELECT COUNT(*) FROM del_oi) AS oi_deleted;
  \\\"\""
  ```

  Expected: `pj_deleted=1, outcomes_deleted=1, ap_deleted=1, dr_deleted=1, oi_deleted=1`. Row 62 is untouched.

- [ ] **Step 8: Confirm row 62 is the new T30 baseline**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT COUNT(*) AS published_count FROM publish_jobs WHERE status='published';\\\"\""
  ```

  Expected: `published_count = 1` (row 62 only). This becomes the first honest entry toward Phase 2 T30's revised gate of ≥5 in `published`.

---

## Task 13: HANDOFF.md refresh + final commit + push

**Files:**
- Modify: `HANDOFF.md`

- [ ] **Step 1: Update HANDOFF.md**

  Edits to make (precise, surgical):

  1. **Top banner**: change "13 followups + X investigation + 8 DEPLOYED + 12 CI drift guards" → "14 followups + X investigation + 9 DEPLOYED + 16 CI drift guards" (or whatever the actual count is — verify via `ls apps/outreach-workflows/tests/sha256-audit/*.js | wc -l`).

  2. **Add to the bullet list** under the top banner:
     > - **Postiz-state poll workflow deployed to LXC 112** at <ISO timestamp UTC> (workflow `pOlLpUbLiShReS01`) — closes the `sent_to_postiz` vs actually-published honesty gap. New `outreach-publish-poll` runs every 2 min, lists Postiz posts via one bounded `GET /posts?startDate=&endDate=` call per cycle, and reconciles `publish_jobs` + `outreach_items` to match Postiz `Post.state`. State machine: PUBLISHED → `publish_jobs.published` + `outreach_items.published` (only if currently `reviewed`); ERROR → `failed` + Slack alert; QUEUE age ≥ 30 min → `manual_post_required` + Slack alert; not-in-list → `failed` (orphaned) + Slack alert; unknown state → Slack warning. Workflow D loses its premature `outreach_items.published` write (Rollup node + 3 connection edges deleted). Synthetic smoke verified end-to-end; row 62 caught up on first cycle. 4 new CI guards: `workflow-d-no-rollup-audit`, `poll-workflow-status-writes-audit`, `postiz-list-window-audit`, `poll-reconcile-state-machine` (sandbox). 2 new schema tests: Mark Published idempotence + no-demote. Production-post count semantics: T30 gate is now ≥5 in `published` (not `sent_to_postiz`); current count 1/5. Commits `<commit-shas>`.

  3. **Phase 2 task status table**: add a new row for "Followup 14 — Postiz-state poll workflow" with the deploy timestamp and commit shas.

  4. **Top priority next session**: drop the "(a) Postiz-state poll workflow" item; promote (b) Threading and (c) Verify Hash fix accordingly. Update production-post count to reflect that the gate is now ≥5 `published` rows.

  5. **Open issues**: close #13 (sent_to_postiz != actually published) — mark it resolved by this followup.

  6. **Resume procedure**: drop section 1 (was the Postiz poll); renumber the rest.

  7. **Recent commits**: append the new SHAs from this plan in reverse-chron order.

  Use the existing wording style (terse, surgical, no marketing language). Do this as a single `Edit` operation on the HANDOFF.md file.

- [ ] **Step 2: Commit**

  ```bash
  git add HANDOFF.md
  git commit -m "docs(handoff): Postiz-state poll workflow DEPLOYED; sent_to_postiz honesty gap closed

  Followup 14: outreach-publish-poll workflow live on LXC 112. 4 new CI
  guards + 2 schema tests + Workflow D Rollup deletion. Row 62 caught up
  to status=published on first poll cycle. T30 gate semantics shift from
  '>=5 in sent_to_postiz' to '>=5 in published' (honest terminal)."
  ```

- [ ] **Step 3: Push**

  ```bash
  git push origin outreach/phase0-phase1
  ```

  Expected: fast-forward push. PR #18 picks up the new commit.

- [ ] **Step 4: Confirm CI green on the final push**

  ```bash
  gh pr checks 18 --watch
  ```

  Expected: all 4 jobs PASS.

- [ ] **Step 5: Smoke-verify the live system one more time** (30-second sanity)

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT
    COUNT(*) FILTER (WHERE status='ready')                AS ready_count,
    COUNT(*) FILTER (WHERE status='sent_to_postiz')       AS sent_count,
    COUNT(*) FILTER (WHERE status='published')            AS published_count,
    COUNT(*) FILTER (WHERE status='failed')               AS failed_count,
    COUNT(*) FILTER (WHERE status='manual_post_required') AS manual_count
  FROM publish_jobs;\\\"\""
  ```

  Expected: `published_count >= 1`. Other counts reflect ambient state. Workflow is live.

---

## Self-review notes (engineer running this plan)

When you finish the plan, the spec at `docs/superpowers/specs/2026-05-22-postiz-state-poll-design.md` should map 1:1 onto what was built:

- Section "Architecture & responsibility split" → Tasks 2 (Workflow D edit) + 3 (poll.json)
- Section "State machine" (Section 2) → Task 7 (sandbox test) verifies all 6 vectors
- Section "Mark Published CTE" → Task 3 (poll.json) authors it; Task 8 (schema tests) pins idempotence + no-demote
- Section "Workflow D modifications" → Task 2
- Section "Observability" → Task 3 (Slack nodes + outcomes INSERTs in the Mark+Log nodes); no new Prometheus metrics in v1
- Section "Schema migrations" (none) → none added
- Section "Testing" → Tasks 4, 5, 6, 7 (CI guards + sandbox), Task 8 (schema)
- Section "Deploy plan" → Tasks 9, 10, 11, 12
- Section "Rollback" → restore points in Task 10; rollback via `n8n update:workflow --active=false` documented in spec

If any spec section has no implementing task, STOP and revise the plan before continuing.
