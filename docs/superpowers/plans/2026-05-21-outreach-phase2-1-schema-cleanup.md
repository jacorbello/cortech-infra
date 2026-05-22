# Outreach Phase 2.1 Schema Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two independent schema/UX cleanups deferred from Phase 2:
- **A:** Add `publish_jobs.created_at` so the metrics/runbook queries can stop JOINing to `approvals`.
- **B:** Split `approved_destination` into `approved_platform` (human-readable: e.g. `bluesky`) + `approved_destination` (Postiz integration ID). Today the integration ID is duplicated into both `publish_jobs` columns and `destination_platform` carries no semantic value.

**Architecture:**
- A is a single additive migration + two query updates (postgres_exporter ConfigMap, runbook markdown).
- B is a migration adding `approvals.approved_platform`, plus changes to Workflow C's form-path nodes only (Slack quick-approve path is intentionally untouched this round — it doesn't dispatch and is TODO #3 on its own). The form gets a `<select>` populated dynamically from Postiz `/api/public/v1/integrations`. `publish_jobs.destination_platform` becomes the platform string; `destination_account` keeps the integration ID.

**Tech Stack:** dbmate (Postgres migrations), n8n 2.9.4 self-hosted on LXC 112, postgres-exporter v0.15.0, ArgoCD-managed observability stack.

**Branch:** Stack on `outreach/phase0-phase1` (open PR #18, all CI green). No worktree — these are additive cleanups that belong in the same PR.

**Scope decisions pinned (user-confirmed):**
- Platform dropdown is **dynamic** — Workflow C fetches `/api/public/v1/integrations` at form render time. Slower form load (~200ms HTTP RTT) but always accurate.
- Historic backfill: row 47 → `'bluesky'` (was the pre-CTE-fix Bluesky test, `approved_destination='bluesky'` already), row 62 → `'bluesky'` (T25 E2E success, integration ID `cmpefsrxp0005kbb1ttpbkjnf` was created in T22 Bluesky onboarding). If either turns out to be a different platform on inspection, fix the backfill row before running it.
- Slack approval path stays unchanged this round (covered by HANDOFF TODO #3).

---

## File Structure

**Created:**
- `apps/outreach-schema/db/migrations/20260521130000_publish_jobs_created_at.sql` — A
- `apps/outreach-schema/db/migrations/20260521130100_approvals_approved_platform.sql` — B

**Modified:**
- `apps/outreach-schema/db/schema.sql` — auto-managed by dbmate; will pick up both migrations
- `k8s/observability/exporters/postgres-outreach-exporter/queries-configmap.yaml` — drop JOIN to approvals
- `docs/runbooks/postiz-failed-job-recovery.md` — drop JOIN, simplify query
- `apps/outreach-workflows/n8n/review.json` — Workflow C: add HTTP integrations-fetch node, update `Code Render HTML`, `Build Approval`, `Write Approval (CTE)`
- `HANDOFF.md` — mark items A and B done; refresh known-issue #10 + Phase 2.1 list

**On the live system (not in git):**
- LXC 114 outreach DB — both migrations applied via `pct exec 114 -- su - postgres -c psql` chain
- LXC 112 n8n — re-import + reactivate `outreach-review-notify` workflow after JSON changes
- K3s observability namespace — `kubectl apply -f` the updated postgres-exporter ConfigMap + restart pod

---

## Task A1: Add `publish_jobs.created_at` migration + backfill

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260521130000_publish_jobs_created_at.sql`
- Modify: `apps/outreach-schema/db/schema.sql` (regenerated; surgical edit acceptable per existing pattern)

- [ ] **Step 1: Write the migration file**

```sql
-- migrate:up
ALTER TABLE publish_jobs
  ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Backfill from approvals.approved_at (both rows were inserted in the same Workflow C CTE)
UPDATE publish_jobs pj
SET created_at = a.approved_at
FROM approvals a
WHERE a.id = pj.approval_id;

CREATE INDEX idx_publish_jobs_status_created ON publish_jobs (status, created_at);

-- migrate:down
DROP INDEX idx_publish_jobs_status_created;
ALTER TABLE publish_jobs DROP COLUMN created_at;
```

- [ ] **Step 2: Apply migration on LXC 114 (live system)**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
ALTER TABLE publish_jobs ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT now();
UPDATE publish_jobs pj SET created_at = a.approved_at FROM approvals a WHERE a.id = pj.approval_id;
CREATE INDEX idx_publish_jobs_status_created ON publish_jobs (status, created_at);
INSERT INTO public.schema_migrations (version) VALUES ('20260521130000');
COMMIT;
SQL
\""
```

Expected: `BEGIN ALTER TABLE UPDATE 2 CREATE INDEX INSERT 0 1 COMMIT` (UPDATE row count = current `publish_jobs` count, currently 2).

- [ ] **Step 3: Verify the backfill**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT pj.id, pj.created_at, a.approved_at, (pj.created_at = a.approved_at) AS match FROM publish_jobs pj JOIN approvals a ON a.id = pj.approval_id ORDER BY pj.id;'\""
```

Expected: `match = t` on every row.

- [ ] **Step 4: Update schema.sql**

Two surgical edits to `apps/outreach-schema/db/schema.sql`:
1. Inside the `CREATE TABLE publish_jobs` block, after `payload_hash text NOT NULL,` add: `created_at timestamptz NOT NULL DEFAULT now()`
2. After `CREATE INDEX idx_publish_jobs_status_scheduled`, add: `CREATE INDEX idx_publish_jobs_status_created ON public.publish_jobs USING btree (status, created_at);`
3. Append `('20260521130000')` to the INSERT INTO schema_migrations VALUES list.

- [ ] **Step 5: Run dbmate locally (sanity check the migration round-trip)**

Skip if no local Postgres available; CI will exercise this in the schema job.

- [ ] **Step 6: Commit**

```bash
git add apps/outreach-schema/db/migrations/20260521130000_publish_jobs_created_at.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add publish_jobs.created_at column + backfill

Adds created_at to publish_jobs so observability queries and runbooks can
stop JOINing to approvals just to get an effective creation timestamp.
Backfilled from approvals.approved_at on the live LXC 114 database (both
rows: 47, 62)."
```

---

## Task A2: Update postgres-exporter queries.yaml + apply

**Files:**
- Modify: `k8s/observability/exporters/postgres-outreach-exporter/queries-configmap.yaml`

- [ ] **Step 1: Replace the ready_oldest_age JOIN with a created_at MIN**

Find the `outreach_publish_jobs:` query block. Change the FROM clause from:

```yaml
FROM publish_jobs pj
JOIN approvals a ON a.id = pj.approval_id;
```

…and the `MIN(a.approved_at) FILTER (WHERE pj.status='ready')` expression to:

```yaml
FROM publish_jobs pj;
```

and `MIN(pj.created_at) FILTER (WHERE pj.status='ready')`.

The full block after edit:

```yaml
outreach_publish_jobs:
  query: |
    SELECT
      COALESCE(
        EXTRACT(EPOCH FROM (now() - MIN(pj.created_at) FILTER (WHERE pj.status='ready')))::bigint,
        0
      ) AS ready_oldest_age_seconds,
      COUNT(*) FILTER (WHERE pj.status='ready')                AS ready_count,
      COUNT(*) FILTER (WHERE pj.status='failed')               AS failed,
      COUNT(*) FILTER (WHERE pj.status='sent_to_postiz')       AS sent_to_postiz,
      COUNT(*) FILTER (WHERE pj.status='manual_post_required') AS manual_required,
      COUNT(*) FILTER (WHERE pj.status='abandoned')            AS abandoned
    FROM publish_jobs pj;
  master: true
  metrics:
    # (unchanged)
```

- [ ] **Step 2: Apply ConfigMap + restart exporter pod**

```bash
ssh root@192.168.1.52 "kubectl apply -f -" < k8s/observability/exporters/postgres-outreach-exporter/queries-configmap.yaml
ssh root@192.168.1.52 "kubectl -n observability rollout restart deploy/postgres-outreach-exporter"
ssh root@192.168.1.52 "kubectl -n observability rollout status deploy/postgres-outreach-exporter --timeout=60s"
```

- [ ] **Step 3: Verify the metric still emits**

```bash
ssh root@192.168.1.52 "kubectl -n observability exec deploy/postgres-outreach-exporter -- wget -qO- http://localhost:9187/metrics 2>/dev/null | grep outreach_publish_jobs_"
```

Expected: same 6 gauges as before, same values (failed=0, abandoned=1, sent_to_postiz=1, others=0).

- [ ] **Step 4: Commit**

```bash
git add k8s/observability/exporters/postgres-outreach-exporter/queries-configmap.yaml
git commit -m "chore(observability): drop approvals JOIN from outreach_publish_jobs query

publish_jobs.created_at now exists; use it directly instead of joining
through approval_id to approvals.approved_at."
```

---

## Task A3: Update failed-job-recovery runbook query

**Files:**
- Modify: `docs/runbooks/postiz-failed-job-recovery.md`

- [ ] **Step 1: Replace the identify-failures query**

Find the query under "## Identify the failures" and replace its body with:

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
psql "$ADMIN_URL" -c "
SELECT pj.id, pj.destination_platform, pj.destination_account,
       pj.attempt_count, LEFT(pj.failure_reason, 120) AS failure_reason, pj.created_at
FROM publish_jobs pj
WHERE pj.status='failed'
ORDER BY pj.created_at DESC LIMIT 20;"
```

- [ ] **Step 2: Remove the explanatory note about the JOIN**

Delete the line: `(publish_jobs has no created_at column; approvals.approved_at is the row's effective creation time since both are inserted in the same CTE.)`

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/postiz-failed-job-recovery.md
git commit -m "docs(runbooks): drop approvals JOIN in failed-job-recovery query"
```

---

## Task B1: Add `approvals.approved_platform` migration + backfill

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260521130100_approvals_approved_platform.sql`
- Modify: `apps/outreach-schema/db/schema.sql`

- [ ] **Step 1: Write the migration**

```sql
-- migrate:up
ALTER TABLE approvals
  ADD COLUMN approved_platform TEXT;

-- Backfill historic rows.
-- Row 47: pre-CTE-fix Bluesky test (approved_destination was the literal 'bluesky' string).
-- Row 62: T25 E2E success against Bluesky integration cmpefsrxp0005kbb1ttpbkjnf.
UPDATE approvals SET approved_platform = 'bluesky'
WHERE id IN (
  SELECT a.id FROM approvals a JOIN publish_jobs pj ON pj.approval_id = a.id
  WHERE pj.id IN (47, 62)
);

-- Make NOT NULL after backfill (no rows should be NULL at this point).
ALTER TABLE approvals
  ALTER COLUMN approved_platform SET NOT NULL,
  ADD CONSTRAINT approvals_approved_platform_check
    CHECK (approved_platform IN ('bluesky','mastodon','reddit','x','linkedin'));

-- migrate:down
ALTER TABLE approvals DROP CONSTRAINT approvals_approved_platform_check;
ALTER TABLE approvals DROP COLUMN approved_platform;
```

- [ ] **Step 2: Verify the backfill query targets the right rows BEFORE applying**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT a.id AS approval_id, pj.id AS pj_id, a.approved_destination FROM approvals a JOIN publish_jobs pj ON pj.approval_id=a.id WHERE pj.id IN (47, 62);'\""
```

Confirm: 2 rows return, both approved_destination values match what you'd expect for Bluesky (row 47 = literal 'bluesky', row 62 = integration ID `cmpefsrxp0005kbb1ttpbkjnf`).

If only the 2 rows return AND user agrees both are Bluesky, proceed. Otherwise STOP and ask the user before backfilling.

- [ ] **Step 3: Apply migration on LXC 114**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
ALTER TABLE approvals ADD COLUMN approved_platform TEXT;
UPDATE approvals SET approved_platform = 'bluesky'
WHERE id IN (SELECT a.id FROM approvals a JOIN publish_jobs pj ON pj.approval_id = a.id WHERE pj.id IN (47, 62));
-- Any other historic approvals (without publish_jobs rows) get a placeholder so NOT NULL works.
UPDATE approvals SET approved_platform = 'bluesky' WHERE approved_platform IS NULL;
ALTER TABLE approvals ALTER COLUMN approved_platform SET NOT NULL;
ALTER TABLE approvals ADD CONSTRAINT approvals_approved_platform_check
  CHECK (approved_platform IN ('bluesky','mastodon','reddit','x','linkedin'));
INSERT INTO public.schema_migrations (version) VALUES ('20260521130100');
COMMIT;
SQL
\""
```

Note: the second UPDATE is a safety net for approvals that exist without publish_jobs rows (Phase 1 testing detritus, save_for_later, rejected decisions). The CHECK constraint will catch any future writes that omit the field.

- [ ] **Step 4: Verify the constraint works**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='approvals'::regclass AND contype='c';\\\"\""
```

Expected: `approvals_approved_platform_check` shows up with the IN-list of platforms.

- [ ] **Step 5: Update schema.sql**

Surgical edits:
1. In the `CREATE TABLE approvals` block, add: `approved_platform text NOT NULL` (place near approved_destination)
2. Add CONSTRAINT line: `CONSTRAINT approvals_approved_platform_check CHECK ((approved_platform = ANY (ARRAY['bluesky'::text, 'mastodon'::text, 'reddit'::text, 'x'::text, 'linkedin'::text])))`
3. Append `('20260521130100')` to the schema_migrations INSERT list.

- [ ] **Step 6: Commit**

```bash
git add apps/outreach-schema/db/migrations/20260521130100_approvals_approved_platform.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add approvals.approved_platform column

Adds a semantic platform field separate from the integration ID. Phase 2
duplicated the integration ID into both publish_jobs.destination_platform
and .destination_account. This migration adds the layer needed to make
the platform field meaningful again. Workflow C form changes in follow-up
commits will populate it from a Postiz integrations dropdown."
```

---

## Task B2: Workflow C — fetch integrations from Postiz before form render

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` (Workflow C: outreach-review-notify)

- [ ] **Step 1: Add an HTTP Request node "Fetch Postiz Integrations"**

The node should sit between `Fetch Form Data` (or whatever node feeds `Code Render HTML`) and `Code Render HTML` itself. Use these parameters:

```json
{
  "parameters": {
    "method": "GET",
    "url": "https://postiz-internal.plotlens-marketing.svc.cluster.local:3000/api/public/v1/integrations",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "options": {}
  },
  "credentials": {
    "httpHeaderAuth": { "id": "<existing-postiz-auth-credential-id>", "name": "postiz-api-key" }
  },
  "type": "n8n-nodes-base.httpRequest",
  "typeVersion": 4.2,
  "name": "Fetch Postiz Integrations"
}
```

Confirm the credential ID by reading `apps/outreach-workflows/credentials-matrix.yaml` for the publish-dispatcher's Postiz credential (Workflow D also uses it). Reuse the same credential reference.

If the in-cluster URL doesn't work from LXC 112 (it almost certainly doesn't — LXC 112 is outside k8s), use `https://postiz.corbello.io/api/public/v1/integrations` through the LXC 100 NGINX reverse proxy. **Verify which URL Workflow D's Postiz Create Post node uses and copy that pattern.**

- [ ] **Step 2: Wire it into the connections object**

The new node needs to be in the chain between the data-fetch and the renderer. Update the `connections` block so:
- `Fetch Form Data` → `Fetch Postiz Integrations` → `Code Render HTML`
- Or whatever the actual node names are.

Run the audit script to confirm wiring:

```bash
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```

- [ ] **Step 3: Pass integrations to Code Render HTML**

The renderer node accesses input items via `$input.item.json`. Update its code so it can also access the integrations list via `$('Fetch Postiz Integrations').all()[0].json`. The shape returned by Postiz `/integrations` should be a JSON array of `{id, name, providerIdentifier, ...}`. The renderer will receive both the form data and this list in scope.

- [ ] **Step 4: Smoke test the fetch in isolation**

After re-import, manually trigger Workflow C with a known approval ID via:

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"curl -sS https://n8n.corbello.io/webhook/render-approval-form?id=<id> -o /tmp/form.html && head -200 /tmp/form.html\"'"
```

Expected: form HTML renders without errors. (If the integrations fetch fails, n8n will throw and the form returns 500 — that's the failure signal.)

- [ ] **Step 5: Commit (defer until B3 done; combined commit)**

---

## Task B3: Workflow C — render the platform dropdown in Code Render HTML

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` (Code Render HTML node)

- [ ] **Step 1: Read the current Code Render HTML jsCode**

Use the inspector pattern from prior work:

```bash
python3 -c "
import json
d = json.load(open('apps/outreach-workflows/n8n/review.json'))
docs = d if isinstance(d, list) else [d]
for doc in docs:
  for n in doc.get('nodes', []):
    if n.get('name') == 'Code Render HTML':
      print(n['parameters']['jsCode'])
"
```

- [ ] **Step 2: Add a platform dropdown before the existing destination input**

In the form HTML template (find the `<label>Approved destination:` block), insert ABOVE it:

```html
<label>Approved platform:
  <select name="approved_platform" required>
    ${integrations.map(intg => `<option value="${escapeHtml(intg.providerIdentifier)}" data-account-id="${escapeHtml(intg.id)}">${escapeHtml(intg.name)} (${escapeHtml(intg.providerIdentifier)})</option>`).join('')}
  </select>
</label><br>
```

And modify the destination input to derive its default from the integration:

```html
<label>Approved destination (Postiz integration ID):
  <input name="approved_destination" value="${escapeHtml(integrations[0]?.id || item.suggested_destination)}">
</label><br>
```

(The user can still override; default picks the first integration's ID.)

- [ ] **Step 3: Make the integrations variable available**

At the top of the renderer's JS, after `const item = rows[0]`, add:

```js
const integrations = $('Fetch Postiz Integrations').all()[0].json || [];
if (integrations.length === 0) {
  return [{json: {html: '<h1>No Postiz integrations configured — cannot render form</h1>'}}];
}
```

This fails fast if Postiz returns empty/null, surfacing the issue immediately.

- [ ] **Step 4: Re-export Workflow C and audit**

After editing the JSON, export from n8n (if working through the UI) or commit the JSON file directly. Run:

```bash
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```

- [ ] **Step 5: Commit (combined with B2)**

```bash
git add apps/outreach-workflows/n8n/review.json
git commit -m "feat(workflow-c): platform dropdown sourced from Postiz integrations API

Adds a 'Fetch Postiz Integrations' HTTP node before Code Render HTML and
extends the form with a required <select name=\"approved_platform\">
populated from the live integrations list. Falls back to a clear error
page if Postiz returns no integrations."
```

---

## Task B4: Workflow C — validate approved_platform in Build Approval + include in hash

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` (Build Approval node)

- [ ] **Step 1: Read current Build Approval code; locate the destination/hash section**

Find the section near `const destination = body.approved_destination || '';`. Insert validation logic:

```js
const VALID_PLATFORMS = ['bluesky','mastodon','reddit','x','linkedin'];
const platform = body.approved_platform;
if (!platform || !VALID_PLATFORMS.includes(platform)) {
  throw new Error('Invalid or missing approved_platform: "' + platform + '" (must be one of: ' + VALID_PLATFORMS.join(', ') + ')');
}
```

- [ ] **Step 2: Include platform in the hash AND in the returned object**

Update the hash line to include platform, so Workflow D's hash verifier and Workflow C's writer compute the same thing:

```js
const hash = sha256(finalText + destination + postType + platform);
```

(Note: this means any in-flight approvals in `publish_jobs.status='ready'` would fail Workflow D's hash check after this change goes live. Confirm there are 0 ready rows first; otherwise re-queue them after the workflow change deploys.)

Update the returned object to include `approved_platform: platform`.

- [ ] **Step 3: Update the corresponding Verify Hash code in publish-dispatcher.json**

Workflow D's `Verify Hash` recomputes `sha256(text + destination + post_type)`. It must also include platform. Update its hash line to:

```js
const computed = sha256(text + destination + postType + platform);
```

…and add `const platform = $input.item.json.approved_platform;` near the other field reads.

- [ ] **Step 4: Re-run the SHA-256 audit + drift check**

```bash
node apps/outreach-workflows/tests/sha256-audit/audit.js
```

Expected: drift check still confirms all 5 copies are bit-for-bit identical (the sha256 function body itself is untouched; only call sites change). 23/23 pass.

- [ ] **Step 5: Confirm no ready rows are in flight**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c 'SELECT COUNT(*) FROM publish_jobs WHERE status=\\\"ready\\\";'\""
```

Expected: 0. If non-zero, STOP — the in-flight rows will fail hash verification after deploy. Either wait for them to dispatch first, or abandon them.

---

## Task B5: Workflow C — Write Approval CTE inserts approved_platform, sets destination_platform from it

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` (Write Approval (CTE) node)

- [ ] **Step 1: Read the current CTE query**

Look at the `Write Approval (CTE)` node's `parameters.query`. It currently INSERTs into approvals with 8 columns and a 9th `outreach_item_id` via $9 used by upd2/upd3 etc. The publish_jobs INSERT inside the `pj` CTE looks like:

```sql
INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
SELECT ins.id, ins.approved_destination, ins.approved_destination, 'postiz_immediate', ins.approved_content_hash
FROM ins
WHERE ins.decision = 'approved'
```

(or similar — confirm the actual shape by reading it.)

- [ ] **Step 2: Add approved_platform to the approvals INSERT**

Change the approvals INSERT column list and VALUES to include `approved_platform` as a new positional placeholder. If the form path uses $1..$8 today + $9 for outreach_item_id, the new column should slot in cleanly — e.g. add at the end of the approvals columns as $10 (so existing positional references in upd1/upd2/upd3 don't break).

- [ ] **Step 3: Change the pj CTE to use ins.approved_platform for destination_platform**

Replace the pj CTE's `destination_platform` source. The new shape:

```sql
INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
SELECT ins.id,
       ins.approved_platform,      -- semantic platform string ('bluesky' etc)
       ins.approved_destination,   -- Postiz integration ID
       'postiz_immediate',
       ins.approved_content_hash
FROM ins
WHERE ins.decision = 'approved'
```

- [ ] **Step 4: Update queryReplacement array in the node options to pass approved_platform**

The `queryReplacement` JSON array form must include the new field. Add `$('Build Approval').item.json.approved_platform` at the right positional index.

- [ ] **Step 5: Re-export + audit**

```bash
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```

- [ ] **Step 6: Commit B4+B5 together**

```bash
git add apps/outreach-workflows/n8n/review.json apps/outreach-workflows/n8n/publish-dispatcher.json
git commit -m "feat(workflow-c,workflow-d): split approved_destination semantics

- Build Approval validates body.approved_platform against the same
  allow-list as the schema constraint, and includes it in the SHA-256
  hash payload alongside destination + post_type.
- Write Approval (CTE) inserts approved_platform into approvals and
  uses it (not the integration ID) for publish_jobs.destination_platform.
- Workflow D's Verify Hash node includes approved_platform in its
  recompute so the hash verifier still matches end-to-end.

publish_jobs.destination_platform is now a human-readable platform
string ('bluesky','mastodon',...) instead of a duplicate of
destination_account. Slack quick-approve path is intentionally
untouched in this round (HANDOFF TODO #3)."
```

---

## Task B6: Deploy Workflow C + D changes to LXC 112 n8n

**Files:**
- Modify (on LXC 112): n8n database

- [ ] **Step 1: scp updated JSONs to LXC 112**

```bash
scp apps/outreach-workflows/n8n/review.json root@192.168.1.52:/tmp/review.json
scp apps/outreach-workflows/n8n/publish-dispatcher.json root@192.168.1.52:/tmp/publish-dispatcher.json
ssh root@192.168.1.52 "pct push 112 /tmp/review.json /root/review.json"
ssh root@192.168.1.52 "pct push 112 /tmp/publish-dispatcher.json /root/publish-dispatcher.json"
```

- [ ] **Step 2: Import + reactivate both workflows**

```bash
ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'cd /root && n8n import:workflow --input=review.json && n8n import:workflow --input=publish-dispatcher.json'"
```

Then capture each workflow's ID and reactivate:

```bash
ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'cd /root && n8n list:workflow | grep -E \"outreach-review|publish-dispatcher\"'"
```

For each ID returned:

```bash
ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'n8n update:workflow --id=<ID> --active=true'"
```

- [ ] **Step 3: Restart n8n service**

```bash
ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'systemctl restart n8n.service'"
sleep 10
ssh root@192.168.1.52 "pct exec 112 -- bash -lc 'systemctl status n8n.service | head -10'"
```

Expected: active (running).

---

## Task B7: Smoke test the end-to-end form path

- [ ] **Step 1: Confirm a draft is in `needs_human_review` status**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT d.id, d.outreach_item_id FROM drafts d WHERE d.status='needs_human_review' AND d.variant='helpful_only' LIMIT 1;\\\"\""
```

If none exists, create one with a synthetic outreach_item + draft via Workflow A trigger, or insert directly with a unique outreach_item_id.

- [ ] **Step 2: Render the form**

Open `https://n8n.corbello.io/webhook/render-approval-form?outreach_item_id=<id>` in a browser. Confirm:
1. The new `Approved platform` dropdown appears
2. The dropdown is populated from Postiz integrations (you should see at minimum the Bluesky integration)
3. The destination input pre-fills with the first integration's ID
4. The existing chosen_variant select and approved_post_type input still work

- [ ] **Step 3: Submit an approval; confirm DB and dispatch**

Click Approve. Then:

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c \"psql -d outreach -c \\\"SELECT a.id, a.approved_platform, a.approved_destination, pj.id AS pj_id, pj.destination_platform, pj.destination_account, pj.payload_hash FROM approvals a JOIN publish_jobs pj ON pj.approval_id=a.id ORDER BY a.id DESC LIMIT 1;\\\"\""
```

Expected:
- `approved_platform` = the platform value you picked (e.g. 'bluesky')
- `destination_platform` (publish_jobs) = same value, NOT the integration ID
- `destination_account` = integration ID
- `payload_hash` is non-empty

Wait 2 minutes and check the publish_jobs row again. Status should transition `ready → sent_to_postiz`. If hash mismatch fires instead, Workflow C and Workflow D's hash logic don't match — re-check Task B4 Step 3.

- [ ] **Step 4: Commit the smoke-test results in HANDOFF**

Update HANDOFF.md to note the platform-split is end-to-end verified and the existing TODOs are resolved.

---

## Task B8: Final HANDOFF.md update + push

- [ ] **Step 1: Update HANDOFF.md**

- Mark items A and B done in the TODO list (currently #5 and #6).
- Update branch commit-count and HEAD pointer.
- Refresh Recent Commits.
- Mark known-issue #10 ("publish_jobs has no created_at") as ✅ FIXED with the migration commit.
- Update Live system state postgres_exporter section to reflect the simplified query.

- [ ] **Step 2: Push all commits**

```bash
git push origin outreach/phase0-phase1
```

- [ ] **Step 3: Wait for CI green on PR #18**

```bash
gh pr view 18 --json statusCheckRollup --jq '.statusCheckRollup[] | {name, conclusion}'
```

All four jobs (schema, audit, sha256-audit, manifests-lint) must be SUCCESS. The schema job specifically will exercise both new migrations + their down paths.

---

## Risks and rollback

**A:** Adding a column with DEFAULT now() and an index is fully reversible (`migrate:down` drops both). The backfill is idempotent (re-running would UPDATE all rows to their JOIN-computed value, which is already correct after first run).

**B:** The Workflow C/D JSON changes are atomic at workflow-import time. If hash logic ends up mismatched, every dispatch fails with `Hash mismatch` (the same failure mode as row 47). Mitigation: confirm 0 `ready` rows before deploy (Task B4 Step 5) and re-run the sha256-audit before pushing. If the form fails to render after the integrations-fetch node is added, revert the workflow via `git checkout apps/outreach-workflows/n8n/review.json && scp` (and reimport on LXC 112).

**Schema CHECK constraint:** `approvals_approved_platform_check` rejects writes with any other platform value. Adding a new platform later requires another migration (same pattern as the `'abandoned'` status addition).
