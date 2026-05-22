# Verify Hash Grandfathered Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the grandfathered exception for `publish-dispatcher.json:Verify Hash` in `apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js` by fixing the array-wrapped return in Workflow D (`outreach-publish-dispatcher`, id `pUbLiShDiSpAtCh01`) and proving via synthetic smoke that the fix doesn't break the publish pipeline.

**Architecture:** Single one-line code edit in the `Verify Hash` Code node (`return [{json: ...}];` → `return {json: ...};`), audit cleanup (delete the `GRANDFATHERED` Set entry + surrounding comment block), and a live synthetic smoke through the full dispatcher path. Risk-managed by: (a) a pre-deploy gate requiring `SELECT COUNT(*) FROM publish_jobs WHERE status='ready'` to be 0 at cutover so no in-flight job fails hash verification during the swap, and (b) a `n8n export:workflow` restore-point snapshot taken before any pct push.

**Tech Stack:** n8n 2.9.4 self-hosted on LXC 112, Postgres on LXC 114 (192.168.1.83), Postiz public API at `https://postiz.corbello.io/api/public/v1`.

**Branch:** Continue on `outreach/phase0-phase1` (open PR #18). Single focused commit at the end — no worktree needed.

**Why this is gated:**
- T25 (publish_jobs row 62, the only successful Phase 2 production publish) succeeded with Workflow D in its current array-wrap shape. Empirically, n8n's `validateRunCodeEachItem` tolerated the pattern with the Postgres-row upstream item shape, even though the exact same pattern crashed in `review.json:Assert Slack Blocks Sent` (upstream = Slack v2 response shape). Until the fix is deployed and smoke-tested, we cannot prove the new bare-object shape works through this dispatcher path.
- Touching Workflow D requires explicit user consent (auto-mode classifier blocked editing `publish-dispatcher.json` last session).
- LXC 112 `n8n.service` restart needs per-event consent — Jeremy is actively using n8n for Phase 1 operational validation.

---

## File Structure

**Modified:**
- `apps/outreach-workflows/n8n/publish-dispatcher.json` — `Verify Hash` Code node, single-line return-shape change
- `apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js` — drop the `GRANDFATHERED` Set entry + surrounding comment block
- `HANDOFF.md` — mark Verify Hash fix DONE, refresh known-issue / TODO list + recent commits

**On the live system (not in git):**
- LXC 112 `/root/publish-dispatcher.json` (intermediate copy for `n8n import:workflow`)
- LXC 112 n8n DB — re-import + reactivate `pUbLiShDiSpAtCh01`
- LXC 112 systemd — `systemctl restart n8n.service` (per-event consent required)
- Optional cleanup of any synthetic Postiz post created by the smoke test

**Restore points:**
- `/tmp/pub-disp-before.json` on the cortech master (snapshot from `n8n export:workflow` before any change)
- `apps/outreach-workflows/n8n/publish-dispatcher.json` at HEAD before the edit (recoverable via `git checkout HEAD -- <path>`)

---

## Task 1: Pre-flight verification

**Files:** none modified; read-only checks only

- [ ] **Step 1: Confirm the user has authorized this work in chat**

  Workflow D edits and an `n8n.service` restart need explicit consent. Do not proceed past Task 2 without it. If the user hasn't said go, stop here and report state.

- [ ] **Step 2: Confirm 0 ready publish_jobs rows (race-window check, first pass)**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT COUNT(*) FILTER (WHERE status='ready') AS ready_count, COUNT(*) FILTER (WHERE status='sent_to_postiz') AS sent_count FROM publish_jobs;\\\"\""
  ```

  Expected: `ready_count = 0`, `sent_count >= 1` (row 62 from T25; will grow once Phase 1 validation produces more posts).

  If `ready_count > 0`, STOP. Either wait for the dispatcher's next 2-min cycle to pick them up, or escalate to the user. In-flight jobs MUST clear before any hash-shape change goes live or they will fail Verify Hash at cutover.

- [ ] **Step 3: Confirm `Verify Hash` is still in the grandfathered shape (sanity check, no drift since handoff)**

  ```bash
  python3 -c "
  import json
  d = json.load(open('apps/outreach-workflows/n8n/publish-dispatcher.json'))
  docs = d if isinstance(d, list) else [d]
  for doc in docs:
      for n in doc.get('nodes', []):
          if n.get('name') == 'Verify Hash':
              code = n['parameters'].get('jsCode', '')
              print('mode:', n['parameters'].get('mode'))
              print('last line:', code.rstrip().split('\n')[-1])
  "
  ```

  Expected output:
  ```
  mode: runOnceForEachItem
  last line: return [{json: {...item, hash_verified: true}}];
  ```

  If the mode or return-shape differs, STOP and re-read this plan against the current file state before proceeding.

- [ ] **Step 4: Confirm the audit currently has the grandfather entry**

  ```bash
  grep -n "publish-dispatcher.json:Verify Hash" apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  ```

  Expected: exactly 1 match inside the `GRANDFATHERED` Set. If 0 matches, this plan is stale — either someone already addressed it or the file moved.

- [ ] **Step 5: Confirm the audit currently passes (baseline)**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  ```

  Expected: exit 0, output includes `SKIP (grandfathered): publish-dispatcher.json:Verify Hash` and `PASS: no Code-node return-shape mismatches.`

- [ ] **Step 6: Confirm the full sha256-audit baseline still 37 pass**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/audit.js
  ```

  Expected: `37 passed` (per HANDOFF as-of the prior session's "37 pass" reference; this is the audit.js core count, not including the +2 standalone guards). If the count differs from 37, note it in the final HANDOFF update and re-baseline against current HEAD before proceeding.

---

## Task 2: Snapshot the live workflow (restore point)

**Files:** none in repo; produces `/tmp/pub-disp-before.json` on cortech master

- [ ] **Step 1: Export the active Workflow D from LXC 112 n8n DB**

  ```bash
  ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"n8n export:workflow --id=pUbLiShDiSpAtCh01 --output=/root/pub-disp-before.json && wc -c /root/pub-disp-before.json\"'"
  ```

  Expected: a positive byte count (~10-12 KB), no `n8n` errors.

- [ ] **Step 2: Pull the snapshot to the cortech master tmp dir**

  ```bash
  ssh root@192.168.1.52 "pct pull 112 /root/pub-disp-before.json /tmp/pub-disp-before.json && wc -c /tmp/pub-disp-before.json"
  ```

  Expected: byte count matches Step 1.

- [ ] **Step 3: Verify the snapshot is well-formed JSON and contains the grandfathered shape**

  ```bash
  ssh root@192.168.1.52 "python3 -c \"
  import json
  d = json.load(open('/tmp/pub-disp-before.json'))
  docs = d if isinstance(d, list) else [d]
  for doc in docs:
      for n in doc.get('nodes', []):
          if n.get('name') == 'Verify Hash':
              code = n['parameters'].get('jsCode', '')
              print('last line:', code.rstrip().split('\\n')[-1])
  \""
  ```

  Expected: `last line: return [{json: {...item, hash_verified: true}}];`

  If the snapshot doesn't parse or doesn't contain the expected shape, STOP — without a known-good restore point we can't safely cut over. Re-run the export and investigate.

---

## Task 3: Edit `Verify Hash` return shape in the repo

**Files:**
- Modify: `apps/outreach-workflows/n8n/publish-dispatcher.json`

- [ ] **Step 1: Apply the surgical edit via Python (jq's escaping bit us last session)**

  Run this script from the repo root. It mutates the file in place after validating the exact match.

  ```bash
  python3 <<'PY'
  import json, sys
  path = 'apps/outreach-workflows/n8n/publish-dispatcher.json'
  with open(path) as f:
      d = json.load(f)
  docs = d if isinstance(d, list) else [d]
  target_old = 'return [{json: {...item, hash_verified: true}}];'
  target_new = 'return {json: {...item, hash_verified: true}};'
  hits = 0
  for doc in docs:
      for n in doc.get('nodes', []):
          if n.get('name') != 'Verify Hash':
              continue
          code = n['parameters'].get('jsCode', '')
          if target_old not in code:
              print(f'FAIL: target_old not found in Verify Hash jsCode', file=sys.stderr)
              sys.exit(1)
          n['parameters']['jsCode'] = code.replace(target_old, target_new)
          hits += 1
  if hits != 1:
      print(f'FAIL: expected exactly 1 Verify Hash node, found {hits}', file=sys.stderr)
      sys.exit(1)
  with open(path, 'w') as f:
      json.dump(d, f, indent=2, sort_keys=False, ensure_ascii=False)
      f.write('\n')
  print('OK: 1 Verify Hash node rewritten')
  PY
  ```

  Expected stdout: `OK: 1 Verify Hash node rewritten`. Non-zero exit means abort and investigate before re-running.

- [ ] **Step 2: Confirm the diff is minimal and correct**

  ```bash
  git diff apps/outreach-workflows/n8n/publish-dispatcher.json
  ```

  Expected: exactly one hunk inside the `jsCode` string of the `Verify Hash` node — a single line changing from `return [{json: {...item, hash_verified: true}}];` to `return {json: {...item, hash_verified: true}};`. The diff should be exactly two changed characters worth of content (drop the leading `[` and trailing `]`). No churn elsewhere in the file — no key-reorder hunks, no whitespace deltas in other nodes, no trailing-newline diff.

  If `git diff` shows indentation churn across the file (Python's `json.dump` can re-indent if the input wasn't 2-space already — but HANDOFF confirms commit `13de101` previously had to restore discover.json's indent after a JSON round-trip), check this file's current indent:

  ```bash
  head -3 apps/outreach-workflows/n8n/publish-dispatcher.json
  ```

  If the file isn't 2-space JSON, redo the edit with the Edit tool (exact-match strings) instead of the Python script. Fallback exact-match strings:
  - `old_string`: `return [{json: {...item, hash_verified: true}}];`
  - `new_string`: `return {json: {...item, hash_verified: true}};`

- [ ] **Step 3: Sanity-parse the edited file**

  ```bash
  python3 -c "
  import json
  d = json.load(open('apps/outreach-workflows/n8n/publish-dispatcher.json'))
  docs = d if isinstance(d, list) else [d]
  for doc in docs:
      for n in doc.get('nodes', []):
          if n.get('name') == 'Verify Hash':
              code = n['parameters'].get('jsCode', '')
              last = code.rstrip().split('\n')[-1]
              print('last line:', repr(last))
              assert last == 'return {json: {...item, hash_verified: true}};', 'shape wrong'
  print('OK')
  "
  ```

  Expected: `OK` and `last line: 'return {json: {...item, hash_verified: true}};'`.

---

## Task 4: Remove the grandfather entry from the audit

**Files:**
- Modify: `apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js`

- [ ] **Step 1: Read the current grandfather block to identify the exact span to remove**

  The block is roughly lines 41-52 of `code-node-return-shape-audit.js` (the `// Grandfathered nodes —` comment paragraph plus the `const GRANDFATHERED = new Set([...]);` declaration including the inline `// publish-dispatcher.json — Verify Hash. T25 ...` comment and the string entry).

- [ ] **Step 2: Replace the GRANDFATHERED block with an empty Set kept for forward-compat**

  Use the Edit tool with these exact strings. The point of keeping `GRANDFATHERED = new Set()` (empty) is so the conditional `GRANDFATHERED.has(key)` in `main()` still works syntactically if a future audit-author needs to re-add an entry — and so the change is minimal/diff-friendly.

  - `old_string`:
    ```
    // Grandfathered nodes — the bug pattern is present but production behaviour
    // has been observed (e.g. T25 row 62 SUCCESS for Workflow D Verify Hash).
    // Why these pass: the n8n validator's tolerance varies with the upstream
    // node's pairedItem shape; some inputs happen to flatten cleanly through
    // the array wrapper, others (like the Slack v2 response shape) do not.
    // Touching live Workflow D is out of scope for this fix bundle (session
    // boundary). New violations should still fail — only the explicit set below
    // is allowed, and each entry MUST cite the reason it's grandfathered.
    const GRANDFATHERED = new Set([
      // publish-dispatcher.json — Verify Hash. T25 (row 62) succeeded with this
      // shape; full deploy + smoke pending future work. Tracked in HANDOFF.
      'publish-dispatcher.json:Verify Hash',
    ]);
    ```
  - `new_string`:
    ```
    // No entries today. Verify Hash was the last grandfather, removed once the
    // fix + smoke test proved n8n tolerates the bare-object shape end-to-end.
    // If a future violation has a justified reason to skip, add it here with
    // an inline citation (mode, upstream-node shape, smoke-test evidence).
    const GRANDFATHERED = new Set();
    ```

- [ ] **Step 3: Verify the audit still passes after the edit (locally, against the modified workflow)**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  ```

  Expected: exit 0, no `SKIP (grandfathered):` line, every `runOnceForEachItem` Code node listed as `OK`, ending with `PASS: no Code-node return-shape mismatches.`

  If FAIL, the most likely cause is Task 3's edit didn't actually swap the return shape — re-check `git diff apps/outreach-workflows/n8n/publish-dispatcher.json`.

- [ ] **Step 4: Re-run the core sha256 audit to confirm no regression**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/audit.js
  ```

  Expected: same pass count as Task 1 Step 6 (37). If the count drops, investigate — the JSON round-trip may have shifted other helper-function bodies.

- [ ] **Step 5: Re-run the related drift guards to be safe**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/platform-map-audit.js
  node apps/outreach-workflows/tests/sha256-audit/hash-payload-order.js
  node apps/outreach-workflows/tests/sha256-audit/blocksui-shape-audit.js
  node apps/outreach-workflows/tests/sha256-audit/webhook-rawbody-audit.js
  node apps/outreach-workflows/tests/sha256-audit/slack-signature-end-to-end.js
  node apps/outreach-workflows/tests/sha256-audit/no-public-self-loop.js
  node apps/outreach-workflows/tests/sha256-audit/normalize-rss-no-followit.js
  node apps/outreach-workflows/tests/sha256-audit/normalize-rss-thin-excerpt-skip.js
  ```

  All must exit 0. If any guard fails, the JSON round-trip likely re-ordered keys or shifted whitespace inside a fixture-checked node. Restore the file via `git checkout HEAD -- apps/outreach-workflows/n8n/publish-dispatcher.json` and re-do Task 3 Step 1 with the Edit tool's exact-match path instead of the Python script.

---

## Task 5: Re-confirm the pre-deploy gate (second pass, immediately before cutover)

**Files:** none modified

- [ ] **Step 1: Re-query ready publish_jobs (race window since Task 1 may be hours stale)**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT id, status, destination_platform, created_at FROM publish_jobs WHERE status IN ('ready','dispatching') ORDER BY created_at DESC;\\\"\""
  ```

  Expected: zero rows. If any rows return, STOP. Either wait for the dispatcher's next 2-min cycle, or escalate to the user. Deploying with in-flight jobs WILL cause Verify Hash failures.

- [ ] **Step 2: Confirm with the user that an `n8n.service` restart is OK right now**

  Restart interrupts Jeremy's active session. Get explicit "go" before Task 6.

---

## Task 6: Deploy Workflow D to LXC 112

**Files:**
- Modify (on LXC 112 only): n8n DB row for `pUbLiShDiSpAtCh01`

- [ ] **Step 1: Push the edited JSON to LXC 112**

  ```bash
  scp apps/outreach-workflows/n8n/publish-dispatcher.json root@192.168.1.52:/tmp/publish-dispatcher.json
  ssh root@192.168.1.52 "pct push 112 /tmp/publish-dispatcher.json /root/publish-dispatcher.json && pct exec 112 -- ls -la /root/publish-dispatcher.json"
  ```

  Expected: file present on LXC 112, ~10-12 KB, mtime fresh.

- [ ] **Step 2: Import the workflow into n8n**

  ```bash
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'cd /root && n8n import:workflow --input=publish-dispatcher.json'"
  ```

  Expected: `Successfully imported 1 workflow.` (or n8n's equivalent — exact wording is version-dependent). Non-zero exit means abort and restore from `/tmp/pub-disp-before.json`.

- [ ] **Step 3: Reactivate the workflow (import resets active state)**

  ```bash
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'n8n update:workflow --id=pUbLiShDiSpAtCh01 --active=true'"
  ```

  Expected: confirmation line containing `pUbLiShDiSpAtCh01` and `active=true` (or equivalent).

- [ ] **Step 4: Restart n8n service (consent confirmed in Task 5 Step 2)**

  ```bash
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'systemctl restart n8n.service'"
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'systemctl status n8n.service --no-pager | head -15'"
  ```

  Expected: `Active: active (running)` within a few seconds of the restart.

- [ ] **Step 5: Verify the activation in the journal**

  ```bash
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'journalctl -u n8n.service --since=\"2 minutes ago\" --no-pager | grep -E \"Activated workflow|publish-dispatcher|ERROR\"'"
  ```

  Expected: a line `Activated workflow "outreach-publish-dispatcher"`. No `ERROR` lines referencing the workflow. If there is an error referencing the Verify Hash code, jump immediately to the rollback path (Task 9).

- [ ] **Step 6: Confirm the new shape persisted in the live DB (round-trip sanity)**

  Avoid nested heredoc quoting; write a tiny check script to a temp file and `pct push` it. Run from cortech master.

  ```bash
  cat >/tmp/check-verify-hash.py <<'PY'
  import json, sys
  d = json.load(open('/tmp/pub-disp-after.json'))
  docs = d if isinstance(d, list) else [d]
  for doc in docs:
      for n in doc.get('nodes', []):
          if n.get('name') == 'Verify Hash':
              code = n['parameters'].get('jsCode', '')
              last = code.rstrip().split('\n')[-1]
              print('last line:', last)
              sys.exit(0 if last == 'return {json: {...item, hash_verified: true}};' else 1)
  print('FAIL: Verify Hash node not found', file=sys.stderr)
  sys.exit(2)
  PY
  scp /tmp/check-verify-hash.py root@192.168.1.52:/tmp/check-verify-hash.py
  ssh root@192.168.1.52 "pct push 112 /tmp/check-verify-hash.py /root/check-verify-hash.py"
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'n8n export:workflow --id=pUbLiShDiSpAtCh01 --output=/tmp/pub-disp-after.json && python3 /root/check-verify-hash.py'"
  ```

  Expected: `last line: return {json: {...item, hash_verified: true}};` and exit 0. If still showing the array-wrapped shape, the import didn't take — check n8n logs and re-import.

---

## Task 7: Synthetic smoke test (end-to-end through the dispatcher)

**Goal:** Insert a synthetic `publish_jobs` row that passes Verify Hash, gets picked up by the next 2-min dispatcher cycle, and transitions `ready → sent_to_postiz`. Cleanup of any real Postiz post comes in Task 8.

**Note on synthetic-row design (uncertain — needs human confirmation):** A "fully synthetic" row that never touches Postiz would require either (a) stubbing out the Postiz Create Post node temporarily, which adds risk, or (b) crafting a row whose Postiz call deliberately fails *after* Verify Hash but before publish (e.g. invalid integration ID — but then the dispatcher transitions to `failed`, not `sent_to_postiz`, so we can't actually prove the success path). The simplest reliable design is to mimic B7's smoke from the schema-cleanup plan: a real synthetic approval that produces a real Postiz post which is then deleted manually. **Confirm with the user before executing Step 3 below.** If the user prefers a no-real-post approach, fall back to (b) and only assert that the dispatcher gets past Verify Hash (status moves out of `ready`) rather than asserting `sent_to_postiz`.

**Files:** none modified in repo; produces a row in `outreach.publish_jobs` + possibly a Postiz post

- [ ] **Step 1: Pull row 62's source-of-truth values (the only successful Phase 2 publish)**

  Workflow D's `Fetch Ready` query computes `final_text = COALESCE(a.edited_text, d.draft_text)` and `Verify Hash` recomputes `sha256(final_text + approved_destination + approved_post_type + approved_platform)` (verified by reading `apps/outreach-workflows/n8n/publish-dispatcher.json` directly). Row 62 is the canonical reference — pull its **exact** approval values so the synthetic mimics what the dispatcher actually saw on the success path.

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT a.approved_destination, a.approved_post_type, a.approved_platform, a.approved_content_hash FROM approvals a JOIN publish_jobs pj ON pj.approval_id = a.id WHERE pj.id = 62;'\""
  ```

  Capture all four columns verbatim. They are the source of truth — do not assume the Postiz integration ID is the right `approved_destination`; whatever row 62 stored is what Workflow D successfully hashed against. Call the captured values:
  - `REF_DEST` ← `approved_destination`
  - `REF_POST_TYPE` ← `approved_post_type`
  - `REF_PLATFORM` ← `approved_platform`

  Use exactly those values (no substitutions) when building the synthetic hash + INSERT in Steps 2 and 3.

- [ ] **Step 2: Compute a fresh hash for the synthetic row OFFLINE**

  Workflow D hashes `final_text + approved_destination + approved_post_type + approved_platform` (confirmed by inspecting the `Verify Hash` jsCode in `apps/outreach-workflows/n8n/publish-dispatcher.json`). The `final_text` it sees comes from `COALESCE(a.edited_text, d.draft_text)` in `Fetch Ready` — so writing the smoke string to `drafts.draft_text` (and leaving `approvals.edited_text` NULL) makes the COALESCE return the smoke string. Use a short, obviously-test final_text and the row-62 reference values from Step 1.

  ```bash
  node -e "
  const crypto = require('crypto');
  const finalText = 'synthetic-verify-hash-smoke-' + new Date().toISOString();
  const destination = '<REF_DEST>';
  const postType = '<REF_POST_TYPE>';
  const platform = '<REF_PLATFORM>';
  const h = crypto.createHash('sha256').update(finalText + destination + postType + platform).digest('hex');
  console.log('final_text=' + finalText);
  console.log('hash=' + h);
  "
  ```

  Substitute `<REF_DEST>`, `<REF_POST_TYPE>`, `<REF_PLATFORM>` with the values captured from row 62 in Step 1. Capture both stdout lines — they feed the SQL in Step 3 as `SYN_FINAL_TEXT` and `SYN_HASH`.

  **NOTE:** Workflow D uses the pure-JS SHA-256 (memory `n8n-crypto-require-blocked`); the Node.js `crypto.createHash` here is just a reference implementation that produces the same digest. If the smoke fails with `Hash mismatch`, the bug is in our pure-JS sha256 helper drift — but `audit.js`'s bit-identity guard (Followup 6) would have caught that, so this is unlikely.

- [ ] **Step 3: ONLY AFTER USER OK — insert the synthetic approval + publish_jobs row**

  This will produce a real Postiz post (for whatever platform row 62 used) unless Task 7 prelude's option (b) is chosen. Get explicit confirmation.

  Schema reality-check (read directly from `apps/outreach-schema/db/schema.sql`):
  - `outreach_items` NOT NULL columns: `source_platform`, `source_url`, `status`. Timestamp column is `discovered_at` (not `created_at`). No `draft_count` column exists.
  - `drafts` NOT NULL columns include `outreach_item_id`, `variant`, `model_provider`, `model_name`, `prompt_version`, `draft_text`, `suggested_destination`, `suggested_post_type`, `content_hash`, `status`. The smoke string goes in `draft_text`.
  - `approvals` columns are `draft_id`, `approved_by` (NOT NULL), `decision`, `edited_text` (nullable — leave NULL so `COALESCE` returns `drafts.draft_text`), `approved_destination`, `approved_platform`, `approved_post_type`, `approved_content_hash`, `approval_notes`, `approved_at`, `expires_at`. There is **no** `final_text`, `outreach_item_id`, `chosen_variant`, or `final_text` column on `approvals` — earlier plan drafts had these wrong.
  - `publish_jobs` requires `approval_id`, `destination_platform`, `destination_account`, `publish_mode`, `payload_hash`. The BEFORE INSERT trigger `enforce_approval_match` will reject the row unless `payload_hash = approvals.approved_content_hash`, `approvals.decision = 'approved'`, and `approvals.expires_at >= now()` — the INSERT below uses the row-62 values to satisfy this.

  Build the SQL in a local file and push it (avoids the nested-heredoc quoting issues that bit a previous session, per memory `LXC 114 credential-less psql`):

  ```bash
  cat >/tmp/verify-hash-smoke.sql <<'SQL'
  BEGIN;
  WITH ins_oi AS (
    INSERT INTO outreach_items (source_platform, source_url, source_excerpt, status, discovered_at)
    VALUES ('manual',
            'https://example.com/verify-hash-smoke-' || extract(epoch from now())::bigint,
            'verify hash smoke synthetic (Task 7 of verify-hash-grandfathered-fix plan)',
            'reviewed',
            now())
    RETURNING id
  ),
  ins_d AS (
    INSERT INTO drafts (outreach_item_id, variant, model_provider, model_name, prompt_version,
                        draft_text, suggested_destination, suggested_post_type, content_hash, status, created_at)
    SELECT id, 'helpful_only', 'synthetic', 'smoke-test', 'smoke-verify-hash',
           :'syn_final_text', :'ref_dest', :'ref_post_type', :'syn_hash', 'approved', now()
    FROM ins_oi
    RETURNING id, outreach_item_id
  ),
  ins_a AS (
    INSERT INTO approvals (draft_id, approved_by, decision, edited_text,
                           approved_destination, approved_platform, approved_post_type,
                           approved_content_hash, approval_notes, approved_at)
    SELECT d.id, 'synthetic-smoke', 'approved', NULL,
           :'ref_dest', :'ref_platform', :'ref_post_type',
           :'syn_hash', 'Task 7 smoke — DELETE_ME', now()
    FROM ins_d d
    RETURNING id
  )
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash, status, created_at)
  SELECT id, :'ref_platform', :'ref_dest', 'postiz_immediate', :'syn_hash', 'ready', now()
  FROM ins_a
  RETURNING id, status;
  COMMIT;
  SQL
  scp /tmp/verify-hash-smoke.sql root@192.168.1.52:/tmp/verify-hash-smoke.sql
  ssh root@192.168.1.52 "pct push 114 /tmp/verify-hash-smoke.sql /tmp/verify-hash-smoke.sql"
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -v ON_ERROR_STOP=1 \
    -v syn_final_text='<SYN_FINAL_TEXT>' \
    -v syn_hash='<SYN_HASH>' \
    -v ref_dest='<REF_DEST>' \
    -v ref_platform='<REF_PLATFORM>' \
    -v ref_post_type='<REF_POST_TYPE>' \
    -f /tmp/verify-hash-smoke.sql\""
  ```

  Substitute the angle-bracket placeholders with the values captured in Steps 1 and 2 (psql `-v` handles the SQL quoting via `:'name'` — no shell-escape gymnastics needed).

  Expected: one new `publish_jobs` row id printed with `status='ready'`. Note the id (call it `SYN_PJ_ID`). If the trigger rejects with `publish_job payload_hash does not match approved_content_hash`, recheck that the same `SYN_HASH` was passed to both the approvals row and the publish_jobs row (the CTE uses `:'syn_hash'` in both places, but verify Step 2's hash is what you actually passed in).

- [ ] **Step 4: Wait for the next dispatcher cycle (up to 2 minutes)**

  ```bash
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 15
    echo "[poll $i/12] $(date -u +%H:%M:%S)"
    ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -t -A -c \\\"SELECT id || '|' || status || '|' || COALESCE(postiz_post_id, '-') || '|' || COALESCE(LEFT(failure_reason, 80), '-') FROM publish_jobs WHERE id = <SYN_PJ_ID>;\\\"\""
  done
  ```

  Expected progression: `<SYN_PJ_ID>|ready|-|-` → eventually `<SYN_PJ_ID>|sent_to_postiz|cmpe...|-`. The iteration counter ensures you can spot quickly which 15-second tick the transition happened on.

  - If it stays `ready` for >4 minutes, the dispatcher schedule trigger may have hung — check `journalctl -u n8n.service --since "5 minutes ago"`.
  - If it transitions to `failed` or `manual_required` with `failure_reason` containing `Hash mismatch`, the new shape broke something. JUMP TO TASK 9 (rollback).
  - If it transitions to `failed` with a Postiz-side error (network, auth, integration not found), Verify Hash itself passed — the failure is downstream and unrelated to this change. Note this in the smoke report and continue.

- [ ] **Step 5: Confirm Verify Hash actually ran and emitted hash_verified**

  Check the n8n execution log for the dispatcher run that touched `SYN_PJ_ID`:

  ```bash
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'journalctl -u n8n.service --since=\"5 minutes ago\" --no-pager | grep -iE \"verify hash|hash_verified|hash mismatch\" | tail -20'"
  ```

  Expected: no `Hash mismatch` lines for the synthetic run. If n8n logs at debug level you may see `hash_verified` propagation; if not, the absence of mismatch errors plus the status transition is sufficient.

---

## Task 8: Cleanup synthetic test artifacts

**Files:** none in repo

- [ ] **Step 1: Identify the Postiz post id (if any) created by the smoke**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT id, postiz_post_id, status, created_at FROM publish_jobs WHERE id = <SYN_PJ_ID>;\\\"\""
  ```

  If `postiz_post_id` is non-null and `status='sent_to_postiz'`, a real Postiz draft/post was created.

- [ ] **Step 2: Document the cleanup commands for the user**

  Print the exact deletion commands for the user to run (deletion path varies by Postiz state — scheduled vs published). For an immediately-published Bluesky post, the user can:
  - Open `https://postiz.corbello.io`, find the post in the activity feed, and delete.
  - Or hit the Postiz public API directly (preferred, repeatable):

  ```bash
  # User-run: delete the Postiz post + its provider-side post
  curl -X DELETE "https://postiz.corbello.io/api/public/v1/posts/<postiz_post_id>" \
    -H "Authorization: <POSTIZ_API_KEY>"
  ```

  The previous B7 smoke (HANDOFF) did the manual-delete path through the Postiz UI — that's the safe default.

- [ ] **Step 3: Mark the synthetic publish_jobs / approvals / drafts / outreach_items rows for archival (optional, no harm leaving them)**

  Tag them so future operators understand they're synthetic. The smoke chain is uniquely identifiable via:
  - `outreach_items.source_url LIKE 'https://example.com/verify-hash-smoke-%'`
  - `approvals.approval_notes = 'Task 7 smoke — DELETE_ME'`
  - `drafts.model_provider = 'synthetic'` AND `prompt_version = 'smoke-verify-hash'`

  Archival path (recommended — fast and idempotent):

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -v ON_ERROR_STOP=1 -c \\\"UPDATE outreach_items SET status='archived' WHERE id = (SELECT outreach_item_id FROM drafts WHERE id = (SELECT draft_id FROM approvals WHERE id = (SELECT approval_id FROM publish_jobs WHERE id = <SYN_PJ_ID>)));\\\"\""
  ```

  Leaving the `publish_jobs` row itself in `sent_to_postiz` is fine — it counts toward Phase 2 T30's "≥5 production posts" gate, though arguably the synthetic shouldn't count. User's call. If the user wants the synthetic chain physically removed (e.g. to keep T30's count clean), see Task 9 Step 3's deletion CTE for an FK-ordered teardown — it works on the success path too.

---

## Task 9: Rollback path (only if Task 7 detected breakage)

Do NOT execute this if Task 7 passed.

- [ ] **Step 1: Push the snapshot back to LXC 112**

  ```bash
  ssh root@192.168.1.52 "pct push 112 /tmp/pub-disp-before.json /root/publish-dispatcher.json"
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'cd /root && n8n import:workflow --input=publish-dispatcher.json'"
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'n8n update:workflow --id=pUbLiShDiSpAtCh01 --active=true'"
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'systemctl restart n8n.service'"
  sleep 5
  ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'systemctl status n8n.service --no-pager | head -10'"
  ```

  Expected: live workflow back to the grandfathered shape, `n8n.service` active.

- [ ] **Step 2: Revert the repo edits**

  ```bash
  git checkout HEAD -- apps/outreach-workflows/n8n/publish-dispatcher.json apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  node apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  ```

  Expected: audit passes again with `SKIP (grandfathered): publish-dispatcher.json:Verify Hash`.

- [ ] **Step 3: Mark the failed synthetic row as `abandoned` and archive the upstream rows**

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -v ON_ERROR_STOP=1 -c \\\"UPDATE publish_jobs SET status='abandoned', failure_reason='verify-hash-fix smoke rollback' WHERE id=<SYN_PJ_ID>;\\\"\""
  ```

  Then archive the synthetic upstream rows (set `outreach_items.status='archived'` so they don't pollute future scans). The `drafts` / `approvals` rows can stay — they're FK-anchored to the archived outreach_item and the smoke is identifiable via `approval_notes = 'Task 7 smoke — DELETE_ME'`:

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -v ON_ERROR_STOP=1 -c \\\"UPDATE outreach_items SET status='archived' WHERE id = (SELECT outreach_item_id FROM drafts WHERE id = (SELECT draft_id FROM approvals WHERE id = (SELECT approval_id FROM publish_jobs WHERE id = <SYN_PJ_ID>)));\\\"\""
  ```

  If you want to delete the synthetic chain entirely (cleaner, but FK-ordered):

  ```bash
  ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -v ON_ERROR_STOP=1 <<'SQL'
  BEGIN;
  WITH chain AS (
    SELECT pj.id AS pj_id, a.id AS approval_id, d.id AS draft_id, d.outreach_item_id AS oi_id
    FROM publish_jobs pj
    JOIN approvals a ON a.id = pj.approval_id
    JOIN drafts d ON d.id = a.draft_id
    WHERE pj.id = <SYN_PJ_ID>
  )
  DELETE FROM publish_jobs WHERE id IN (SELECT pj_id FROM chain);
  -- repeat the chain CTE before each DELETE because the prior DELETE invalidates the join path
  DELETE FROM approvals WHERE id IN (SELECT approval_id FROM (
    SELECT a.id AS approval_id FROM approvals a JOIN drafts d ON d.id = a.draft_id WHERE d.outreach_item_id IN (
      SELECT id FROM outreach_items WHERE source_url LIKE 'https://example.com/verify-hash-smoke-%'
    )
  ) s);
  DELETE FROM drafts WHERE outreach_item_id IN (SELECT id FROM outreach_items WHERE source_url LIKE 'https://example.com/verify-hash-smoke-%');
  DELETE FROM outreach_items WHERE source_url LIKE 'https://example.com/verify-hash-smoke-%';
  COMMIT;
  SQL
  \""
  ```

  Default to the archival path (faster, idempotent, safe). Use the delete path only if the user asks for full cleanup.

- [ ] **Step 4: Report the failure mode**

  Capture the exact `Hash mismatch` / error message + the n8n execution-log line. The grandfather entry stays (with an updated inline citation referencing the failed smoke attempt). The plan can be re-attempted later with more upstream-shape investigation.

---

## Task 10: Commit + HANDOFF update

(Run this only if Task 7 passed and you did not enter Task 9.)

- [ ] **Step 1: Confirm the working tree is clean except for the planned changes**

  ```bash
  git status
  git diff --stat
  ```

  Expected modifications: `apps/outreach-workflows/n8n/publish-dispatcher.json`, `apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js`. (HANDOFF.md will be modified in Step 4.)

- [ ] **Step 2: Run the full pre-commit guard suite one last time**

  ```bash
  node apps/outreach-workflows/tests/sha256-audit/audit.js \
    && node apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js \
    && node apps/outreach-workflows/tests/sha256-audit/platform-map-audit.js \
    && node apps/outreach-workflows/tests/sha256-audit/hash-payload-order.js \
    && node apps/outreach-workflows/tests/sha256-audit/blocksui-shape-audit.js \
    && node apps/outreach-workflows/tests/sha256-audit/webhook-rawbody-audit.js \
    && node apps/outreach-workflows/tests/sha256-audit/slack-signature-end-to-end.js \
    && node apps/outreach-workflows/tests/sha256-audit/no-public-self-loop.js \
    && node apps/outreach-workflows/tests/sha256-audit/normalize-rss-no-followit.js \
    && node apps/outreach-workflows/tests/sha256-audit/normalize-rss-thin-excerpt-skip.js \
    && echo ALL_GUARDS_PASS
  ```

  Expected final line: `ALL_GUARDS_PASS`. If any guard fails, do NOT commit.

- [ ] **Step 3: Single conventional-commit (no AI attribution)**

  ```bash
  git add apps/outreach-workflows/n8n/publish-dispatcher.json apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js
  git commit -m "fix(outreach): unwrap Verify Hash return shape + remove grandfather

  Workflow D's Verify Hash Code node ran in mode=runOnceForEachItem but
  returned [{json: ...}] (array-wrapped). The same pattern crashed
  review.json:Assert Slack Blocks Sent (Followup 11); T25 row 62 had
  empirically tolerated it through the publish-dispatcher path so we
  grandfathered it with an inline citation while we figured out a safe
  cutover. This change swaps it to the bare {json: ...} shape n8n's
  validateRunCodeEachItem actually wants, and drops the GRANDFATHERED
  entry in code-node-return-shape-audit.js (left as an empty Set so
  future justified skips still have a place).

  Deploy gate: 0 ready publish_jobs at cutover; LXC 112 snapshot in
  /tmp/pub-disp-before.json as restore point. Synthetic smoke row went
  ready -> sent_to_postiz on the next dispatcher cycle."
  ```

  Verify the commit:

  ```bash
  git log -1 --stat
  git log -1 --format='%B' | grep -iE "claude|anthropic|generated with|co-authored" || echo NO_AI_ATTRIBUTION
  ```

  Expected: `NO_AI_ATTRIBUTION`. If anything matches, amend the commit message and re-check.

- [ ] **Step 4: Update HANDOFF.md**

  Edits:
  1. Remove the "Verify Hash proper fix (task #128)" section from "Top priority next session" (it's now done).
  2. Add a row to the followups table (or a new "Followup 12 — Verify Hash unwrap" entry) with the same shape as Followup 11: deploy timestamp, root cause recap, fix, smoke result, commit hash.
  3. Update the "Top priority next session" section to drop the Verify Hash item.
  4. Update the "Recent commits" block to include the new commit hash + message.
  5. Update the audit count if it changed (per Task 1 Step 6 + Task 10 Step 2 — should still be 37 for `audit.js`; the `code-node-return-shape-audit.js` now passes without skips but doesn't change the audit.js count).
  6. Update known-issue list: if there's a numbered entry tracking the grandfather, mark it ✅ FIXED with the new commit hash.

- [ ] **Step 5: Commit the HANDOFF update separately**

  ```bash
  git add HANDOFF.md
  git commit -m "docs(handoff): Verify Hash unwrap deployed; grandfather removed"
  git log -1 --format='%B' | grep -iE "claude|anthropic|generated with|co-authored" || echo NO_AI_ATTRIBUTION
  ```

  Expected: `NO_AI_ATTRIBUTION`.

- [ ] **Step 6: Push and wait for CI on PR #18**

  ```bash
  git push origin outreach/phase0-phase1
  gh pr view 18 --json statusCheckRollup --jq '.statusCheckRollup[] | {name, conclusion}'
  ```

  Wait until all 4 checks (`schema`, `audit`, `sha256-audit`, `manifests-lint`) report `conclusion: SUCCESS`. The `sha256-audit` job is the load-bearing one for this change — it must run all 10 guards and pass.

---

## Risks and rollback

- **The new shape breaks Verify Hash through the publish-dispatcher upstream-item path.** Mitigated by the synthetic smoke in Task 7 + the immediate-restore path in Task 9 using the `/tmp/pub-disp-before.json` snapshot. The only window where production is exposed is between Task 6 Step 4 (restart) and Task 7 Step 4 (status transition observed) — ~2-3 minutes. The pre-deploy gate (Task 5 Step 1) eliminates the only failure mode in that window (in-flight `ready` jobs failing hash check at cutover).
- **JSON round-trip churn from Python's `json.dump`.** Mitigated by `git diff` review in Task 3 Step 2 + the Edit-tool fallback path with exact-match strings. Discover.json had this exact issue in commit `13de101`; the script's `indent=2` should match the file's existing shape but verify before committing.
- **Synthetic smoke produces a real Bluesky post.** Mitigated by short, obviously-test final_text + Task 8 cleanup. If the user objects to producing a real post, fall back to Task 7's alternative path (deliberately-failing Postiz call after a passing Verify Hash) — but acknowledge that path proves only the negative ("not Verify Hash") rather than the positive (`sent_to_postiz`).
- **Audit count drift.** If `audit.js`'s pass count changes from 37 after the JSON edit, the SHA-256 helper family bit-identity guard (Followup 6) is the most likely tripwire — would indicate the JSON re-serialization shifted whitespace inside one of the sha256 helper bodies. Recovery: redo the edit via Edit tool with exact-match strings instead of Python.
- **Postiz API base-path / auth-header drift.** Not modified here, but the smoke's `crypto.createHash` reference computation depends on the pure-JS sha256 in Workflow D being bit-identical to Node's `crypto`. Already pinned by Followup 6's RFC 4231 vectors + the helper-family drift check.
