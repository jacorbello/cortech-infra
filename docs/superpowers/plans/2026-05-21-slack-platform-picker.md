# Slack Platform-Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Workflow C Slack quick-approve flow so Jeremy can pick a platform/integration at click-time. Today `Build Slack Approval` hardcodes `approved_platform='bluesky'` and routes `suggested_destination` (e.g. `bluesky_post`) into `approved_destination` — which is the wrong shape (Workflow D's `destination_account` needs a Postiz integration ID, not a label). After this plan: each Slack notification carries one "Approve" button per available Postiz integration; clicking any of them stamps both the platform string and the Postiz integration ID into `approvals` + `publish_jobs` in a hash-payload-consistent way that Workflow D's `Verify Hash` accepts.

**Architecture:**
- `Build Slack Blocks` emits N approve buttons (one per known integration), each with `action_id = approve_<platform_key>_<oid>`. The single Reject button stays as `reject_<oid>`. Platform keys are stable internal identifiers: `bluesky_brand`, `bluesky_personal`, `mastodon`.
- `Verify Slack Signature` parses the new tri-segment `verb_platformkey_oid` format on approve, and the existing bi-segment `verb_oid` for reject. Emits `verb`, `platform_key` (null for reject), and `outreach_item_id`.
- `Build Slack Approval` reads `platform_key`, looks up the matching Postiz integration ID + semantic platform string in an inline `PLATFORM_MAP`, sets both `approved_platform` and `approved_destination` correctly, and computes the SHA-256 hash with the chosen platform. This is byte-for-byte hash-compatible with Workflow D's `Verify Hash` (payload = `finalText + destination + postType + platform`).
- `Write Slack Approval (CTE)` — no SQL change needed; queryReplacement positions 1-10 stay aligned. The `pj` CTE was already gated on `decision='approved' AND length(approved_destination) > 0` (Phase 2.1 followup 2), so it now correctly enqueues with a real integration ID.
- `HTTP Confirm Approval` surfaces the chosen platform in the ephemeral reply.
- `sha256()` helper in `Build Slack Approval` stays byte-identical to the other four copies; the `apps/outreach-workflows/tests/sha256-audit/audit.js` audit must keep passing.

**Tech Stack:** n8n 2.9.4 self-hosted on LXC 112, Postgres on LXC 114, Slack Block Kit (`button` actions only — see design decision 2).

**Branch:** Stack on `outreach/phase0-phase1` (open PR #18). NO new branch. NO worktree — this is a one-file workflow JSON edit + a doc edit, narrow enough to share PR #18.

---

## Hard constraints (bake into every commit/PR/doc — DO NOT VIOLATE)

1. **NO AI ATTRIBUTIONS** anywhere — not in commit messages, code comments, doc artifacts, PR descriptions, or anywhere else. (User CLAUDE.md global rule.)
2. **Do NOT redeploy / re-import to LXC 112 n8n in any implementer-executed task.** Jeremy is actively using n8n for Phase 1 operational validation. The deploy step is controller-executed only, gated on user confirmation.
3. **Pre-deploy gate:** 0 `ready` rows in `publish_jobs` before cutover (hash payload shape stays the same in this plan, so this is belt-and-suspenders — but still required).
4. **Hash payload shape is fixed:** `sha256(finalText + destination + postType + platform)`. Workflow D's `Verify Hash` is the source of truth. Workflow C's `Build Slack Approval` MUST match.
5. **sha256() byte-identity:** `apps/outreach-workflows/tests/sha256-audit/audit.js` extracts the embedded sha256 function from all five Code nodes and asserts MD5 identity. The plan does NOT modify the `sha256()` helper at all — only code after it. Re-run after every edit.
6. **psql access:** Use `ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql ...\""` exclusively. NEVER pull `OUTREACH_DB_ADMIN_URL` from Infisical.

---

## Design decisions (pinned by planner; do not re-litigate during implementation)

### Decision 1 — Hardcoded platform→integration-id map (Option A)

The map lives inline in the Code nodes. Rationale: Slack interactive ack must return within ~3s; one extra HTTP hop to `/api/public/v1/integrations` per click is avoidable load on the speed path, and the form path already has the dynamic-fetch behavior so we don't lose that capability anywhere. With three known integrations (and channel adds being a deliberate operator action — see Decision 4), the maintenance cost is a one-line constant edit per channel.

### Decision 2 — Multi-button cluster, no `static_select` (Pattern Y)

Each approve action is its own button: "Approve → Bluesky (PlotLens)", "Approve → Bluesky (personal)", "Approve → Mastodon". One Reject button stays. Rationale:
- 3 platforms fits comfortably in a single `actions` block (Slack allows 25 elements per `actions` block).
- The picked platform is encoded directly in `action_id`, which the existing `Verify Slack Signature` parser already reads. No `state_values` traversal, no separate "Submit" coordination, no transient state between select-change and approve-click.
- Trivial visual scan in Slack: Jeremy sees the choice already named on the button.
- Scaling beyond ~5 platforms would warrant `static_select` later; this plan does not block that migration.

### Decision 3 — Map duplicated inline in `Build Slack Blocks` AND `Build Slack Approval`

Two small const blocks, side-by-side in the same JSON file, with a `// PLATFORM MAP — keep in sync with the copy in Build Slack Approval / Build Slack Blocks` comment in each. Rationale: a shared "Set Platform Map" node adds wiring (Webhook → Set Map → Verify Slack Signature → … breaks the existing linear chain in two places) for the savings of duplicating four lines. Auditable at a glance; sync-rule is documented (Decision 4).

### Decision 4 — Channel onboarding sync procedure

When a new Postiz integration is added (a new Bluesky brand, a new Mastodon instance, etc.), the operator MUST:
1. Update the `PLATFORM_MAP` constant in BOTH `Build Slack Blocks` and `Build Slack Approval` nodes inside `apps/outreach-workflows/n8n/review.json`.
2. Re-import + reactivate the `outreach-review-notify` workflow on LXC 112.
3. Verify by clicking the new approve button on a real outreach item.

This procedure is added as a checklist line in `docs/runbooks/postiz-channel-onboarding.md` under a new "Slack quick-approve registration" subsection (Task 9).

No periodic resync. Three integrations, deliberate operator actions, low drift risk.

---

## File Structure

**Modified:**
- `apps/outreach-workflows/n8n/review.json` — `Build Slack Blocks`, `Verify Slack Signature`, `Build Slack Approval`, `HTTP Confirm Approval` (4 Code/HTTP nodes). `Write Slack Approval (CTE)` UNCHANGED (queryReplacement position 10 already feeds `approved_platform`).
- `docs/runbooks/postiz-channel-onboarding.md` — append "Slack quick-approve registration" subsection.
- `HANDOFF.md` — close TODO #1, mark Slack platform-picker shipped under a new "Phase 2.1 follow-ups (post-handoff)" subsection.

**Not modified:**
- `apps/outreach-workflows/n8n/publish-dispatcher.json` (Workflow D) — hash payload shape unchanged; no edit.
- `apps/outreach-workflows/tests/sha256-audit/audit.js` — re-run only, no edit.
- Any other `n8n/*.json`, schema migrations, or k8s manifests.

**On the live system (NOT in implementer-executed scope):**
- LXC 112 n8n re-import + reactivation — controller-executed, gated on user confirmation (Task 9).

---

## Task 1 — Pre-flight: capture baseline state

**Files:** none (read-only commands)

- [ ] **Step 1: Verify branch + worktree state**

```bash
cd /home/jacorbello/repos/cortech-infra
git status -s   # expect clean
git branch --show-current   # expect: outreach/phase0-phase1
git log --oneline main..HEAD | head -3
```

Expected: clean, on `outreach/phase0-phase1`, top commit is `fd985c5 docs(outreach): n8n workflow reference guide` (or later if other commits land first).

- [ ] **Step 2: Verify 0 `ready` rows in publish_jobs (pre-deploy gate, baseline)**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT COUNT(*) FROM publish_jobs WHERE status='\\''ready'\\'';'\""
```

Expected: `count = 0`. If non-zero, STOP and report to controller — the hash-shape change in this plan is binary-safe (payload format unchanged), but a stale `ready` row hints at an in-flight dispatch and the controller decides.

- [ ] **Step 3: Capture review.json baseline checksum**

```bash
md5sum apps/outreach-workflows/n8n/review.json
```

Record the hash. Useful for confirming the only-this-file scope at the end.

- [ ] **Step 4: Run sha256-audit baseline**

```bash
node apps/outreach-workflows/tests/sha256-audit/audit.js | tail -5
```

Expected: `=== 23 pass, 0 fail ===`. Drift check: all 5 sha256() copies show one MD5. Record the MD5; it must match at the end (this plan does NOT touch the sha256() helper).

- [ ] **Step 5: Confirm the live integration IDs match what's in HANDOFF**

Read-only sanity check; do not call into Postiz unless this is suspicious.

The IDs you will encode in the PLATFORM_MAP are (sourced from HANDOFF "Postiz integrations (live)"):
- `cmpefsrxp0005kbb1ttpbkjnf` — plotlens.bsky.social (brand, default Bluesky for outreach)
- `cmpefkzmt0001kbb1plpudyo3` — jacorbello.bsky.social (personal)
- `cmpegkub20001j0auhv9epe72` — @plotlens@mastodon.social

If you want to double-check against the live Postiz instance (optional, read-only):

```bash
curl -s -H "Authorization: $(ssh root@192.168.1.52 'pct exec 112 -- bash -c "cat /etc/systemd/system/n8n.service.d/slack-env.conf | grep POSTIZ_API_KEY | cut -d= -f2"')" https://postiz.corbello.io/api/public/v1/integrations | python3 -m json.tool | head -50
```

If any ID differs, STOP and surface to controller before editing the JSON.

---

## Task 2 — Update `Build Slack Blocks` to emit per-platform approve buttons

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` — replace the `jsCode` of the `Build Slack Blocks` node (id `cc000010-0010-0010-0010-000000000010`).

The change introduces a `PLATFORM_MAP` constant and replaces the single `approveButton` with a per-platform fan-out. Buttons are ordered: brand Bluesky first (default), Mastodon second, personal Bluesky third. Reject + Open-full-form stay as today.

- [ ] **Step 1: Replace `Build Slack Blocks` jsCode**

Set the node's `parameters.jsCode` (single string, JSON-escaped) to exactly the following JavaScript:

```js
// PLATFORM MAP — keep in sync with the copy in 'Build Slack Approval'.
// When adding a new Postiz integration that should appear in Slack quick-approve:
//   1) Add a row here AND in 'Build Slack Approval'.
//   2) Re-import + reactivate outreach-review-notify on LXC 112.
//   3) See docs/runbooks/postiz-channel-onboarding.md 'Slack quick-approve registration'.
const PLATFORM_MAP = [
  { key: 'bluesky_brand',    platform: 'bluesky',  integration: 'cmpefsrxp0005kbb1ttpbkjnf', label: 'Bluesky (PlotLens)' },
  { key: 'mastodon',         platform: 'mastodon', integration: 'cmpegkub20001j0auhv9epe72', label: 'Mastodon (@plotlens)' },
  { key: 'bluesky_personal', platform: 'bluesky',  integration: 'cmpefkzmt0001kbb1plpudyo3', label: 'Bluesky (personal)' },
];

const item = $input.item.json;
const previewText = String(item.preview_text || '');
const sourceUrl = String(item.source_url || '');
const platform = String(item.source_platform || '');
const risk = item.preview_risk_score;
const oid = item.outreach_item_id;

const headerText = `:memo: *Outreach item #${oid}* — \`${platform}\` — risk *${risk}/100*\n><${sourceUrl}|source>\n>${previewText.replace(/\n/g, '\n>')}`;

const formUrl = `https://n8n.corbello.io/webhook/render-approval-form?outreach_item_id=${oid}`;

const lowRisk = risk < 20;

// Build the approve-per-platform cluster (only when low-risk; high-risk still routes through the form).
const approveButtons = lowRisk
  ? PLATFORM_MAP.map(p => ({
      type: 'button',
      text: { type: 'plain_text', text: `Approve → ${p.label}` },
      action_id: `approve_${p.key}_${oid}`,
      style: 'primary',
    }))
  : [];

const baseButtons = [
  { type: 'button', text: { type: 'plain_text', text: 'Reject' }, action_id: `reject_${oid}`, style: 'danger' },
  { type: 'button', text: { type: 'plain_text', text: 'Open full form' }, url: formUrl },
];

const buttons = [...approveButtons, ...baseButtons];

const blocks = [
  { type: 'section', text: { type: 'mrkdwn', text: headerText } },
  { type: 'actions', elements: buttons },
];

return [{
  json: {
    ...item,
    slack_blocks: blocks,
    slack_text_fallback: `Outreach item #${oid} — risk ${risk}/100 — needs review`,
    is_low_risk: lowRisk,
  }
}];
```

> **Implementer note:** before writing this code, read the CURRENT `Build Slack Blocks` jsCode in `review.json` and confirm the exact `outreach_item_id` field name, `preview_risk_score` field name, and `is_low_risk` flag semantics. If anything differs from the assumptions above, surface to controller before editing — do NOT silently adapt the field names.

To apply, use the Python JSON round-trip pattern that worked in prior Phase 2.1 commits:

```bash
python3 <<'PY'
import json, pathlib
p = pathlib.Path('apps/outreach-workflows/n8n/review.json')
docs = json.loads(p.read_text())
NEW_CODE = r"""<paste the JS above as a Python raw-string>"""
applied = False
for doc in docs if isinstance(docs, list) else [docs]:
    for node in doc.get('nodes', []):
        if node.get('id') == 'cc000010-0010-0010-0010-000000000010':
            assert node['name'] == 'Build Slack Blocks', node['name']
            node['parameters']['jsCode'] = NEW_CODE
            applied = True
assert applied, 'Build Slack Blocks node not found'
p.write_text(json.dumps(docs, ensure_ascii=False))
PY
```

- [ ] **Step 2: Verify the JSON parses + the node still has the expected shape**

```bash
python3 -c "
import json
docs = json.load(open('apps/outreach-workflows/n8n/review.json'))
for doc in (docs if isinstance(docs, list) else [docs]):
    for n in doc.get('nodes', []):
        if n['name'] == 'Build Slack Blocks':
            assert 'PLATFORM_MAP' in n['parameters']['jsCode'], 'PLATFORM_MAP not in updated code'
            assert 'cmpefsrxp0005kbb1ttpbkjnf' in n['parameters']['jsCode'], 'brand bluesky id missing'
            assert 'cmpegkub20001j0auhv9epe72' in n['parameters']['jsCode'], 'mastodon id missing'
            assert 'cmpefkzmt0001kbb1plpudyo3' in n['parameters']['jsCode'], 'personal bluesky id missing'
            print('OK: Build Slack Blocks updated; all 3 integration IDs present')
"
```

Expected: `OK: Build Slack Blocks updated; all 3 integration IDs present`.

---

## Task 3 — Update `Verify Slack Signature` to parse tri-segment approve `action_id`

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` — node `Verify Slack Signature` (id `t29w0002-0002-0002-0002-000000000002`).

Today the parser uses `action_id.indexOf('_')` to split on the first underscore, getting `verb` + `outreachItemIdStr`. The new approve action_ids have the form `approve_<platform_key>_<oid>`, where `platform_key` is one of `bluesky_brand`, `bluesky_personal`, `mastodon`. Reject stays `reject_<oid>`. We need to handle both.

**The sha256 + hmacSha256 helpers MUST NOT be modified.** Only the trailing payload-parsing block changes.

- [ ] **Step 1: Replace ONLY the trailing parser block in `Verify Slack Signature` jsCode**

Locate the block starting at `const payload = JSON.parse(bodyPayload);` and ending at the `return [{json: { ... }}];`. Replace exactly that block with:

```js
const payload = JSON.parse(bodyPayload);
if (!payload.actions || !payload.actions[0]) throw new Error('No actions in Slack payload');
const action = payload.actions[0];
const actionId = action.action_id || '';

// action_id formats:
//   - 'reject_<oid>'                                 (reject button)
//   - 'approve_<platform_key>_<oid>'                 (per-platform approve button; platform_key from PLATFORM_MAP)
// platform_key may contain underscores (e.g. 'bluesky_brand'), so parse from both ends.
const firstUnder = actionId.indexOf('_');
const lastUnder = actionId.lastIndexOf('_');
if (firstUnder < 0) throw new Error('Malformed action_id: ' + actionId);

const verb = actionId.substring(0, firstUnder);
const outreachItemIdStr = actionId.substring(lastUnder + 1);
const outreach_item_id = parseInt(outreachItemIdStr, 10);

if (!['approve', 'reject'].includes(verb)) throw new Error('Unknown verb: ' + verb);
if (isNaN(outreach_item_id) || outreach_item_id <= 0) throw new Error('Invalid outreach_item_id: ' + outreachItemIdStr);

// platform_key is the slice between the first and last underscores (only present on approve).
let platform_key = null;
if (verb === 'approve') {
  if (lastUnder === firstUnder) {
    throw new Error('Approve action_id missing platform_key: ' + actionId);
  }
  platform_key = actionId.substring(firstUnder + 1, lastUnder);
  if (!platform_key) throw new Error('Empty platform_key in action_id: ' + actionId);
} else if (verb === 'reject') {
  // Reject must be bi-segment (reject_<oid>) — extra segments are a bug.
  if (lastUnder !== firstUnder) {
    throw new Error('Reject action_id has unexpected platform_key segment: ' + actionId);
  }
}

const slack_user_id = payload.user && payload.user.id;
const slack_user_name = (payload.user && (payload.user.username || payload.user.name)) || 'unknown';
const response_url = payload.response_url || null;

return [{json: {
  verb,
  platform_key,
  outreach_item_id,
  slack_user_id,
  slack_user_name,
  response_url,
}}];
```

Notes on the parse:
- `approve_bluesky_brand_999` → firstUnder=7, lastUnder=20, verb=`approve`, platform_key=`bluesky_brand`, oid=`999`.
- `approve_mastodon_42` → firstUnder=7, lastUnder=16, verb=`approve`, platform_key=`mastodon`, oid=`42`.
- `reject_999` → firstUnder=6, lastUnder=6, verb=`reject`, platform_key=null, oid=`999`.

- [ ] **Step 2: Apply via the same JSON round-trip pattern**

```bash
python3 <<'PY'
import json, pathlib
p = pathlib.Path('apps/outreach-workflows/n8n/review.json')
docs = json.loads(p.read_text())
NEW_TAIL = r"""<paste the JS block above starting at 'const payload = JSON.parse(bodyPayload);'>"""
applied = False
for doc in (docs if isinstance(docs, list) else [docs]):
    for node in doc.get('nodes', []):
        if node.get('id') == 't29w0002-0002-0002-0002-000000000002':
            assert node['name'] == 'Verify Slack Signature', node['name']
            code = node['parameters']['jsCode']
            i = code.index('const payload = JSON.parse(bodyPayload);')
            node['parameters']['jsCode'] = code[:i] + NEW_TAIL
            applied = True
assert applied, 'Verify Slack Signature node not found'
p.write_text(json.dumps(docs, ensure_ascii=False))
PY
```

- [ ] **Step 3: Verify the sha256() / hmacSha256() helpers were NOT touched**

```bash
node apps/outreach-workflows/tests/sha256-audit/audit.js 2>&1 | grep -E "(drift|FAIL|pass, 0 fail)"
```

Expected: `OK: all 5 copies are bit-for-bit identical (<md5>).` and `=== 23 pass, 0 fail ===`. MD5 must match Task 1 Step 4 baseline.

- [ ] **Step 4: Verify the parser block contains the new fields**

```bash
python3 -c "
import json
docs = json.load(open('apps/outreach-workflows/n8n/review.json'))
for doc in (docs if isinstance(docs, list) else [docs]):
    for n in doc.get('nodes', []):
        if n['name'] == 'Verify Slack Signature':
            c = n['parameters']['jsCode']
            assert 'platform_key' in c, 'platform_key missing'
            assert 'lastIndexOf' in c, 'tri-segment parse missing'
            print('OK: Verify Slack Signature parser updated')
"
```

---

## Task 4 — Update `Build Slack Approval` to derive destination + platform from `platform_key`

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` — node `Build Slack Approval` (id `t29w0006-0006-0006-0006-000000000006`).

**Critical:** the `sha256()` helper at the top of this Code node MUST stay byte-for-byte identical to the other four copies. We are replacing ONLY the trailing block (everything after the `sha256()` function definition).

- [ ] **Step 1: Replace ONLY the trailing payload-build block**

Locate the block starting at `const d = $input.item.json;` and ending at the closing `return [{json: { ... }}];`. Replace exactly that block with:

```js
// PLATFORM MAP — keep in sync with the copy in 'Build Slack Blocks'.
// When adding a new Postiz integration that should appear in Slack quick-approve:
//   1) Add a row here AND in 'Build Slack Blocks'.
//   2) Re-import + reactivate outreach-review-notify on LXC 112.
//   3) See docs/runbooks/postiz-channel-onboarding.md 'Slack quick-approve registration'.
const PLATFORM_MAP = {
  bluesky_brand:    { platform: 'bluesky',  integration: 'cmpefsrxp0005kbb1ttpbkjnf', label: 'Bluesky (PlotLens)' },
  mastodon:         { platform: 'mastodon', integration: 'cmpegkub20001j0auhv9epe72', label: 'Mastodon (@plotlens)' },
  bluesky_personal: { platform: 'bluesky',  integration: 'cmpefkzmt0001kbb1plpudyo3', label: 'Bluesky (personal)' },
};

const d = $input.item.json;
const decision = (d.verb === 'approve') ? 'approved' : 'rejected';
const postType = d.suggested_post_type || '';

// For approve: resolve the platform_key from Verify Slack Signature into a (platform, integration) pair.
// For reject: leave destination/integration blank; the pj CTE is gated on length(approved_destination) > 0 anyway.
// approvals.approved_platform is NOT NULL + CHECK constrained, so reject still needs a valid semantic platform — default to 'bluesky' if no picker hint.
let platform = '';
let destination = '';
let platformLabel = '';
if (decision === 'approved') {
  const key = d.platform_key;
  const entry = PLATFORM_MAP[key];
  if (!entry) {
    throw new Error('Unknown platform_key from Slack: ' + key + ' (expected one of: ' + Object.keys(PLATFORM_MAP).join(', ') + ')');
  }
  platform = entry.platform;
  destination = entry.integration;
  platformLabel = entry.label;
} else {
  // Reject path — platform_key is null (reject button has no platform segment). Default to 'bluesky' to satisfy the CHECK constraint;
  // the value is metadata-only since the pj CTE skips rejects.
  platform = 'bluesky';
}

// Hash payload MUST match Workflow D Verify Hash: finalText + destination + postType + platform.
// For reject, destination is '' and platform is the default; hash is not consumed (pj CTE skips), but we still compute it so the row shape stays consistent.
const hash = sha256(d.draft_text + destination + postType + platform);

return [{json: {
  draft_id: d.draft_id,
  outreach_item_id: d.outreach_item_id,
  approved_by: 'jeremy_slack_' + d.slack_user_name,
  decision: decision,
  edited_text: null,
  approved_destination: destination,
  approved_platform: platform,
  approved_post_type: postType,
  approved_content_hash: hash,
  approval_notes: null,
  response_url: d.response_url,
  slack_user_name: d.slack_user_name,
  platform_label: platformLabel,
}}];
```

> **Implementer note:** before writing this code, read the CURRENT `Build Slack Approval` jsCode and confirm:
> - The input field for the draft text is `d.draft_text` (NOT `d.edited_text` or `d.finalText` — Slack quick-approve has no edit affordance, so it uses the unedited draft).
> - The 10 fields returned in the JSON object map 1:1 to the queryReplacement positions in `Write Slack Approval (CTE)`. If field names differ in the existing node, KEEP the existing names — do NOT rename downstream contracts.

Key correctness notes:
- `approved_destination` is now the Postiz integration ID (e.g. `cmpefsrxp0005kbb1ttpbkjnf`), NOT `suggested_destination` (e.g. `bluesky_post`). This matches the form-path schema introduced by followup-1 / unified dropdown (HANDOFF known-issue #11) where `approved_destination` is the integration ID.
- `approved_platform` is the semantic string (`bluesky` / `mastodon`), satisfying the B1 CHECK constraint.
- For rejects, the hash input is `(draft_text + '' + postType + 'bluesky')`. The `Write Slack Approval (CTE)` `pj` CTE is gated on `decision='approved' AND length(approved_destination) > 0`, so rejects insert into `approvals` only and skip the publish_jobs row — Workflow D never sees the reject hash.
- The schema CHECK on `approvals.approved_platform` allows `'bluesky'`, `'mastodon'`, `'linkedin'`, `'x'`, `'reddit'`. Our `PLATFORM_MAP` values `bluesky` and `mastodon` are both in that set, and the reject default `'bluesky'` is too.

- [ ] **Step 2: Apply via JSON round-trip**

```bash
python3 <<'PY'
import json, pathlib
p = pathlib.Path('apps/outreach-workflows/n8n/review.json')
docs = json.loads(p.read_text())
NEW_TAIL = r"""<paste the trailing block above starting at '// PLATFORM MAP'>"""
applied = False
for doc in (docs if isinstance(docs, list) else [docs]):
    for node in doc.get('nodes', []):
        if node.get('id') == 't29w0006-0006-0006-0006-000000000006':
            assert node['name'] == 'Build Slack Approval', node['name']
            code = node['parameters']['jsCode']
            cut = code.index('const d = $input.item.json;')
            node['parameters']['jsCode'] = code[:cut] + NEW_TAIL
            applied = True
assert applied, 'Build Slack Approval node not found'
p.write_text(json.dumps(docs, ensure_ascii=False))
PY
```

- [ ] **Step 3: Run sha256-audit (CRITICAL — verifies sha256() helper untouched)**

```bash
node apps/outreach-workflows/tests/sha256-audit/audit.js 2>&1 | tail -8
```

Expected output:
- `OK: all 5 copies are bit-for-bit identical (<same md5 as Task 1 Step 4>).`
- `=== 23 pass, 0 fail ===`

If the audit reports drift, REVERT the Build Slack Approval edit (`git checkout apps/outreach-workflows/n8n/review.json`) and re-do Step 2 — the sha256() helper must not have been touched.

- [ ] **Step 4: Verify the new payload-build block compiles offline**

```bash
node -e "
const fs = require('fs');
const docs = JSON.parse(fs.readFileSync('apps/outreach-workflows/n8n/review.json','utf8'));
for (const doc of (Array.isArray(docs) ? docs : [docs])) for (const n of doc.nodes || []) {
  if (n.name === 'Build Slack Approval') {
    try {
      // Stub n8n globals so new Function() can parse; we only need a syntax-check.
      const stubbed = n.parameters.jsCode.replace(/\\\$input/g, '({item:{json:{}}})').replace(/\\\$\\(/g, '(function(){return null;})(');
      new Function(stubbed);
      console.log('OK: syntax parses');
    } catch(e) {
      console.error('FAIL: syntax error:', e.message);
      process.exit(1);
    }
  }
}
"
```

(The replace stubs out n8n-specific globals so `new Function()` doesn't choke; the goal is a parse-only check.)

---

## Task 5 — `Write Slack Approval (CTE)`: verify no change needed

**Files:** `apps/outreach-workflows/n8n/review.json` — node `Write Slack Approval (CTE)` (id `t29w0007-0007-0007-0007-000000000007`). **No edit.**

The current queryReplacement is a 10-element array; position 10 (1-indexed in SQL, index 9 in JS) is `approved_platform`. The SQL CTE references `$10` exactly where it should. Since `Build Slack Approval` (Task 4) still emits `approved_platform` and `approved_destination` keys on the same JSON object, no edit is required.

- [ ] **Step 1: Read-only verification — query + queryReplacement still align**

```bash
python3 -c "
import json
docs = json.load(open('apps/outreach-workflows/n8n/review.json'))
for doc in (docs if isinstance(docs, list) else [docs]):
    for n in doc.get('nodes', []):
        if n['name'] == 'Write Slack Approval (CTE)':
            q = n['parameters']['query']
            qr = n['parameters']['options']['queryReplacement']
            assert '\$10' in q, 'SQL no longer references \$10'
            assert 'approved_platform' in qr, 'queryReplacement no longer reads approved_platform'
            assert qr.count('Build Slack Approval') == 10, 'queryReplacement positions changed (expected 10 references to Build Slack Approval)'
            print('OK: Write Slack Approval (CTE) unchanged — queryReplacement positions still align with Build Slack Approval output')
"
```

If the assertion fails, the upstream Build Slack Approval edit broke a contract — REVERT Task 4 Step 2 and re-do it more carefully.

---

## Task 6 — Update `HTTP Confirm Approval` to surface the chosen platform

**Files:** `apps/outreach-workflows/n8n/review.json` — node `HTTP Confirm Approval` (id `t29w0008-0008-0008-0008-000000000008`).

Today the ephemeral message is a 3-state expression based on `$json.publish_job_id`:
- approved + has publish_job_id → "Approved by X — dispatching to Postiz (job #N)"
- approved + no publish_job_id → "Approved by X as triage-only — no destination set"
- rejected → "Rejected by X"

We extend the dispatched-state message to include the picked platform label.

- [ ] **Step 1: Replace the `jsonBody` expression**

> **Implementer note:** before editing, read the CURRENT `jsonBody` to confirm its expression shape (single-line `={{ JSON.stringify({...}) }}`). The replacement below assumes that shape — if the current node uses `bodyParameters` or a multi-line expression instead, surface to controller for an updated edit.

Set `parameters.jsonBody` to (single-line n8n expression):

```
={{ JSON.stringify({ replace_original: true, text: $('Build Slack Approval').item.json.decision === 'approved' ? ($json.publish_job_id ? ':white_check_mark: Approved by ' + $('Build Slack Approval').item.json.slack_user_name + ' → ' + $('Build Slack Approval').item.json.platform_label + ' — dispatching to Postiz (job #' + $json.publish_job_id + ')' : ':warning: Approved by ' + $('Build Slack Approval').item.json.slack_user_name + ' as triage-only — no destination set, use the form to dispatch') : ':x: Rejected by ' + $('Build Slack Approval').item.json.slack_user_name }) }}
```

`platform_label` is the new field emitted by `Build Slack Approval` (Task 4 Step 1). For the dispatched case it's the human label like `Bluesky (PlotLens)`. For the triage-only case it stays unused (the message doesn't reference it). For reject, `platform_label` is `''` and also unused.

- [ ] **Step 2: Apply via JSON round-trip**

```bash
python3 <<'PY'
import json, pathlib
p = pathlib.Path('apps/outreach-workflows/n8n/review.json')
docs = json.loads(p.read_text())
NEW_BODY = "<paste the ={{ ... }} string above as a single Python string>"
applied = False
for doc in (docs if isinstance(docs, list) else [docs]):
    for node in doc.get('nodes', []):
        if node.get('id') == 't29w0008-0008-0008-0008-000000000008':
            assert node['name'] == 'HTTP Confirm Approval', node['name']
            node['parameters']['jsonBody'] = NEW_BODY
            applied = True
assert applied, 'HTTP Confirm Approval node not found'
p.write_text(json.dumps(docs, ensure_ascii=False))
PY
```

- [ ] **Step 3: Verify the new expression parses + references `platform_label`**

```bash
python3 -c "
import json
docs = json.load(open('apps/outreach-workflows/n8n/review.json'))
for doc in (docs if isinstance(docs, list) else [docs]):
    for n in doc.get('nodes', []):
        if n['name'] == 'HTTP Confirm Approval':
            assert 'platform_label' in n['parameters']['jsonBody'], 'platform_label missing from confirmation message'
            print('OK: HTTP Confirm Approval surfaces platform_label')
"
```

---

## Task 7 — Final integrity checks

**Files:** none (test-only)

- [ ] **Step 1: JSON parse + Python round-trip stable**

```bash
python3 -c "import json; json.load(open('apps/outreach-workflows/n8n/review.json')); print('OK: review.json parses')"
```

- [ ] **Step 2: sha256-audit final pass**

```bash
node apps/outreach-workflows/tests/sha256-audit/audit.js
```

Expected: drift check `OK: all 5 copies are bit-for-bit identical` AND `=== 23 pass, 0 fail ===`. The MD5 must match the Task 1 Step 4 baseline (we did not touch the sha256() helper anywhere).

- [ ] **Step 3: CI schema test sanity (local, optional)**

```bash
cd apps/outreach-schema && bash db/tests/run_tests.sh 2>&1 | tail -10
```

This is a defensive check — the schema didn't change, but a clean pass confirms nothing crashed.

- [ ] **Step 4: Confirm only `review.json` and the runbook + HANDOFF changed**

```bash
git status -s
```

Expected (after Task 9):
```
 M apps/outreach-workflows/n8n/review.json
 M docs/runbooks/postiz-channel-onboarding.md
 M HANDOFF.md
```

If any other files appear modified, STOP and surface to controller.

- [ ] **Step 5: Diff sanity check**

```bash
git diff apps/outreach-workflows/n8n/review.json | head -80
git diff --stat
```

Expected: only the 4 nodes touched (`Build Slack Blocks`, `Verify Slack Signature`, `Build Slack Approval`, `HTTP Confirm Approval`). No `sha256` function body diff (the function body in `Verify Slack Signature` and `Build Slack Approval` was untouched).

---

## Task 8 — Document the channel-onboarding sync rule

**Files:**
- Modify: `docs/runbooks/postiz-channel-onboarding.md` — append a new "Slack quick-approve registration" subsection.

- [ ] **Step 1: Append the subsection**

Append to the end of the file (after the existing X / Mastodon / Bluesky sections):

```markdown
## Slack quick-approve registration

The Slack notification posted by Workflow C (`outreach-review-notify`) shows one
"Approve → <platform>" button per Postiz integration that's registered in the
quick-approve picker. This list is intentionally hardcoded (the Slack speed path
avoids the extra HTTP RTT to `/api/public/v1/integrations`); the form path
fetches dynamically and is unaffected.

When you add a new Postiz integration that should appear in Slack quick-approve:

1. Open `apps/outreach-workflows/n8n/review.json`.
2. Find the `PLATFORM_MAP` constant in BOTH of these nodes — they must stay in sync:
   - `Build Slack Blocks` (id `cc000010-0010-0010-0010-000000000010`) — an array of `{key, platform, integration, label}`.
   - `Build Slack Approval` (id `t29w0006-0006-0006-0006-000000000006`) — an object keyed by the same `key`.
3. Add a row in both. The `key` must be a stable internal identifier (snake_case,
   no spaces). The `platform` must be one of the values allowed by the
   `approvals.approved_platform` CHECK constraint (`bluesky`, `mastodon`,
   `linkedin`, `x`, `reddit`). The `integration` is the Postiz channel ID
   (`cmpe…`). The `label` is the human-readable text shown on the Slack button.
4. Commit the JSON edit on the active branch.
5. Re-import + reactivate the workflow on LXC 112 (controller-only — coordinate
   with the operator before doing this; n8n restarts interrupt active sessions).
6. Verify by clicking the new approve button on a real outreach item; confirm
   `publish_jobs.destination_account` matches the new integration ID and
   Workflow D's `Verify Hash` succeeds.

No periodic resync is performed; this is an operator-driven update tied to the
deliberate act of onboarding a new channel.
```

- [ ] **Step 2: Verify the file still renders**

```bash
grep -A2 "Slack quick-approve registration" docs/runbooks/postiz-channel-onboarding.md | head -5
```

Expected: the new heading + first paragraph appear.

---

## Task 9 — Update HANDOFF.md + commit + push

**Files:**
- Modify: `HANDOFF.md` — append to the Phase 2.1 followups table (or a new "post-handoff followup" subsection) marking Slack platform-picker shipped. Close TODO #1 at the bottom.

- [ ] **Step 1: Update HANDOFF**

Two edits in `HANDOFF.md`:

(a) Under the "Phase 2.1 schema cleanup (final)" table, append a new row at the bottom:

```markdown
| Followup 5 — Slack platform-picker | ✅ | `Build Slack Blocks` now emits one "Approve → <platform>" button per Postiz integration (PLATFORM_MAP: bluesky_brand, mastodon, bluesky_personal). `Verify Slack Signature` parses tri-segment `approve_<platform_key>_<oid>` action_ids. `Build Slack Approval` resolves platform_key into (platform, integration ID) and emits a correctly-shaped hash payload (matches Workflow D Verify Hash). `Write Slack Approval (CTE)` unchanged. `HTTP Confirm Approval` surfaces the picked platform in the ephemeral reply. Channel-onboarding sync rule documented in `docs/runbooks/postiz-channel-onboarding.md`. NOT YET DEPLOYED — awaiting user green-light to re-import on LXC 112 (commit `<TBD>`). |
```

(b) In the "## TODOs for next session" section, strike-through the existing item #1 and replace it with: "1. ~~Slack platform-picker~~ ✅ Followup 5 done. Pending controller-executed re-import on LXC 112 (gated on user confirmation that n8n usage is paused)."

- [ ] **Step 2: Commit (one commit covers JSON + runbook + HANDOFF together — small atomic change)**

NO AI ATTRIBUTIONS. Use the existing repo style (`feat(workflow-c):` prefix matches Phase 2.1 followup commits).

```bash
git add apps/outreach-workflows/n8n/review.json docs/runbooks/postiz-channel-onboarding.md HANDOFF.md
git commit -m "feat(workflow-c): Slack quick-approve platform picker

Build Slack Blocks emits one approve button per Postiz integration
(bluesky_brand, mastodon, bluesky_personal) via a hardcoded PLATFORM_MAP.
Verify Slack Signature parses tri-segment approve_<platform_key>_<oid>
action_ids. Build Slack Approval resolves platform_key into the matching
(platform, integration ID) pair and hashes the chosen platform — payload
shape unchanged, byte-for-byte hash-compatible with Workflow D Verify Hash.
HTTP Confirm Approval surfaces the picked platform in the ephemeral reply.
Channel-onboarding sync rule added to the Postiz runbook.

Pre-deploy gate verified: 0 ready rows in publish_jobs. sha256-audit OK.

NOT deployed to LXC 112 in this commit — re-import is operator-coordinated
to avoid interrupting active Phase 1 validation sessions."
```

(If two commits feel cleaner — one for the JSON, one for the docs — go for it; do not exceed two.)

- [ ] **Step 3: Push to origin**

```bash
git push origin outreach/phase0-phase1
```

- [ ] **Step 4: Wait for CI on PR #18 — green check required**

```bash
gh pr view 18 --json statusCheckRollup --jq '.statusCheckRollup[] | {name, conclusion}'
```

Expected: all 4 checks (schema / audit / sha256-audit / manifests-lint) SUCCESS at the new HEAD. If any check fails, investigate and fix in a follow-up commit.

---

## Task 10 — CONTROLLER-EXECUTED: deploy on LXC 112 (gated on user confirmation)

> **READ CAREFULLY: This task is documentation-only for the implementer subagent. The implementer DOES NOT run any of these commands. The controller runs them after the user explicitly green-lights the deploy.**

**Pre-deploy checklist (controller verifies BEFORE running anything below):**

1. User has explicitly confirmed they are NOT actively using n8n / are willing to accept a brief interruption.
2. Verify 0 `ready` rows in publish_jobs:
   ```bash
   ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT COUNT(*) FROM publish_jobs WHERE status='\\''ready'\\'';'\""
   ```
   Expected: `count = 0`.
3. PR #18 CI green at the new HEAD (Task 9 Step 4 confirms this).

**Deploy commands (controller, after green-light):**

```bash
# Copy the updated workflow JSON to LXC 112 via the cortech-node5 → LXC 112 two-hop
scp apps/outreach-workflows/n8n/review.json root@192.168.1.52:/tmp/review.json
ssh root@192.168.1.52 "scp /tmp/review.json root@192.168.1.80:/tmp/review.json"
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct push 112 /tmp/review.json /tmp/review.json'"

# Deactivate the workflow first (n8n import:workflow needs the workflow inactive on some versions)
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"sudo -u n8n n8n update:workflow --id rEv1eWoUtReAcH001 --active false\"'"

# Import the new JSON
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"sudo -u n8n n8n import:workflow --input=/tmp/review.json\"'"

# Restart n8n.service to pick up the new code-node body cache
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"systemctl restart n8n.service\"'"

# Wait ~10s for n8n to come up, then reactivate
sleep 12
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"sudo -u n8n n8n update:workflow --id rEv1eWoUtReAcH001 --active true\"'"

# Smoke check: workflow is active again
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"sudo -u n8n n8n list:workflow\"'" | grep outreach-review-notify
```

**Post-deploy validation (controller, manual):**

1. Find a low-risk drafted item (risk < 20) in `drafts` table; wait for the next Slack notification cycle (~2min schedule).
2. Verify the Slack message now shows three "Approve → ..." buttons + Reject + Open full form.
3. Click "Approve → Bluesky (PlotLens)" on a test item.
4. Verify the ephemeral reply: ":white_check_mark: Approved by ... → Bluesky (PlotLens) — dispatching to Postiz (job #N)".
5. Verify in DB:
   ```bash
   ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT pj.id, pj.status, pj.destination_platform, pj.destination_account, a.approved_platform FROM publish_jobs pj JOIN approvals a ON a.id = pj.approval_id ORDER BY pj.id DESC LIMIT 3;'\""
   ```
   Expected: newest row has `destination_platform='bluesky'`, `destination_account='cmpefsrxp0005kbb1ttpbkjnf'`, `approved_platform='bluesky'`. Status will be `ready` until the publish-dispatcher runs (~2min), then `sent_to_postiz`.
6. Watch Workflow D in n8n UI for Verify Hash to confirm the dispatch succeeded.

If anything fails: revert by re-importing the previous `review.json` (`git show HEAD~1:apps/outreach-workflows/n8n/review.json > /tmp/review-prev.json`) and surface the failure mode for diagnosis.

---

## Self-review checklist (planner pre-save)

- [x] Four design decisions decided (hardcoded map, multi-button cluster, duplicated-inline location, operator-driven onboarding sync).
- [x] Every code-touching step has concrete code or a concrete diff — no "implement X" placeholders.
- [x] Pre-deploy `SELECT COUNT(*)` command is exact (Task 1 Step 2 + Task 10 pre-deploy checklist).
- [x] sha256-audit is re-run at Task 3 Step 3, Task 4 Step 3, and Task 7 Step 2.
- [x] Deploy task (Task 10) is marked CONTROLLER-EXECUTED and the implementer does not run any of it.
- [x] File paths are absolute / repo-relative + exact (`apps/outreach-workflows/n8n/review.json`, `docs/runbooks/postiz-channel-onboarding.md`, `apps/outreach-workflows/tests/sha256-audit/audit.js`, `HANDOFF.md`).
- [x] Live integration IDs match HANDOFF: `cmpefsrxp0005kbb1ttpbkjnf` (brand BSky, default), `cmpegkub20001j0auhv9epe72` (Mastodon), `cmpefkzmt0001kbb1plpudyo3` (personal BSky).
- [x] AI attributions explicitly forbidden in hard constraints + repeated in Task 9 commit message instructions.
- [x] Branch is `outreach/phase0-phase1`, no worktree, no new branch.
- [x] Hash payload shape (`finalText + destination + postType + platform`) preserved; Workflow D unchanged.
- [x] `Write Slack Approval (CTE)` correctly identified as no-edit (Task 5).
