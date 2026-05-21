# Recovering Failed publish_jobs

A `publish_jobs.status='failed'` row means Workflow D's Postiz Create Post call returned non-2xx or threw. After `attempt_count` reaches 3, the row stays `failed` and is never retried automatically — Workflow D's `Fetch Ready` query filters by `attempt_count < 3`.

## Identify the failures

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
psql "$ADMIN_URL" -c "
SELECT pj.id, pj.destination_platform, pj.destination_account,
       pj.attempt_count, LEFT(pj.failure_reason, 120) AS failure_reason, a.approved_at
FROM publish_jobs pj
JOIN approvals a ON a.id = pj.approval_id
WHERE pj.status='failed'
ORDER BY a.approved_at DESC LIMIT 20;"
```

(`publish_jobs` has no `created_at` column; `approvals.approved_at` is the row's effective creation time since both are inserted in the same CTE.)

Read `failure_reason` to understand the error.

## Common causes and fixes

| failure_reason contains | Likely cause | Fix |
|---|---|---|
| `401 Unauthorized` / `Authorization failed` | Postiz API key revoked, rotated, or wrong header format | Verify the n8n `postiz-api-key` credential value matches `POSTIZ_API_KEY` in Infisical (no `Bearer ` prefix). Regenerate the key in Postiz UI if needed; update Infisical; n8n credential UI; restart `n8n.service` |
| `Bad request` / `All posts must have an integration id` | Workflow D's payload shape regressed | Compare current Postiz HTTP node body against `[[postiz-public-api-conventions]]` memory. Integration must be **inside each `posts[]` entry**, top-level needs `shortLink`, `date`, `tags` |
| `429 Too Many Requests` | Platform rate limit (e.g., X free tier 1500/mo) | Wait until window resets; check the destination platform's quota dashboard; consider raising paid tier |
| `Integration with id ... not found` | Wrong integration ID in `destination_account` | Look up correct ID: `curl -sS -H "Authorization: $API_KEY" https://postiz.corbello.io/api/public/v1/integrations | jq`. Update the approval (DB UPDATE on `approvals.approved_destination`) and re-queue (see below) |
| `Hash mismatch` | Workflow D's defense-in-depth fired | Means the approved text was edited in DB OR the SHA-256 implementation differs. Re-approve the draft via the form. If repeated across many approvals, audit the pure-JS SHA-256 (see roadmap deferred item) |
| `ECONNREFUSED` / `ETIMEDOUT` | Postiz pod down or LXC 100 NGINX unreachable | Check `kubectl get pods -n plotlens-marketing`; check LXC 100 NGINX; see `docs/runbooks/temporal-restart.md` if Temporal is also affected |

## Re-queue a failed job

If the root cause is fixed (e.g., new API key, payload bug patched), reset the row to `ready` with `attempt_count=0`:

```bash
psql "$ADMIN_URL" -c "
UPDATE publish_jobs
SET status='ready', attempt_count=0, failure_reason=NULL
WHERE id=<PUBLISH_JOB_ID>
RETURNING id, status, attempt_count;"
```

Workflow D will pick it up within 2 minutes. Watch for completion:

```bash
psql "$ADMIN_URL" -c "
SELECT id, status, attempt_count, postiz_post_id, LEFT(failure_reason,120), sent_at
FROM publish_jobs WHERE id=<PUBLISH_JOB_ID>;"
```

## Permanently abandon a job

If a publish should never run (wrong destination at approval time, content no longer relevant, etc.):

```bash
psql "$ADMIN_URL" -c "
UPDATE publish_jobs
SET status='abandoned',
    failure_reason = COALESCE(failure_reason,'') || ' [manually abandoned at ' || now()::text || ']'
WHERE id=<PUBLISH_JOB_ID>;"
```

If `status` CHECK constraint rejects `'abandoned'`, add it via a dbmate migration first. Don't bypass the constraint with `DROP CONSTRAINT` — that defeats the schema-level safety.

## When the failure is in the approval itself

If the underlying approval was a mistake (wrong text, wrong destination), use `docs/runbooks/revoke-approval.md`. Revoke the approval (which marks `approvals.status='revoked'` and prevents future dispatches), THEN delete or abandon the failed publish_jobs row.

## Investigating in n8n

For the actual HTTP error body (not just the n8n-summarized `failure_reason`), check n8n executions:

1. `https://n8n.corbello.io` → Executions → filter by workflow `outreach-publish-dispatcher`.
2. Find the failed execution. Click into the `Postiz Create Post` node.
3. Read the response body and headers.

If you need raw access from a shell:

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -lc \"journalctl -u n8n --since=\\\"15 minutes ago\\\" --no-pager | grep -i postiz\"'"
```

## Phase 2 known issues to keep in mind

- `publish_jobs.destination_account` is currently populated from `approvals.approved_destination` via Workflow C's CTE. If approvers paste the wrong Postiz integration ID, the dispatch will fail with `Integration not found`. Re-queue after fixing the destination — don't try to retro-edit `destination_account` directly unless you also bump `payload_hash` (the hash verifier in Workflow D would reject it otherwise).
- The 3-attempt cap is intentional. If you find yourself raising it, escalate — see roadmap "Workflow D retry policy upgrade" trigger.
