# Revoking an Approval Before Its `expires_at`

The `enforce_approval_match` trigger on `publish_jobs` rejects publishes referencing expired approvals. Setting `expires_at` to the past is the canonical way to invalidate an approval — no DELETE required, audit trail preserved.

## When to do this

- The approval was a mistake (wrong text, wrong destination, wrong post type).
- New information makes the post inappropriate before it has been sent.
- An incident requires halting all outbound posting (kill switch).

## Procedure — single approval

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

psql "$ADMIN_URL" -c "
  UPDATE approvals
  SET expires_at = now() - INTERVAL '1 second',
      approval_notes = COALESCE(approval_notes,'') || ' [manually revoked at ' || now()::text || ']'
  WHERE id = <APPROVAL_ID>
  RETURNING id, approved_by, decision, expires_at;
"
```

After this, the `enforce_approval_match` trigger rejects any `publish_jobs` row that references this approval. If the dispatcher tries to create one, it fails fast with `ERROR: approval has expired`.

## Procedure — kill switch (revoke all unsent approvals)

```bash
psql "$ADMIN_URL" -c "
  UPDATE approvals
  SET expires_at = now() - INTERVAL '1 second',
      approval_notes = COALESCE(approval_notes,'') || ' [kill switch revoked at ' || now()::text || ']'
  WHERE decision='approved'
    AND expires_at > now()
    AND id NOT IN (
      SELECT approval_id FROM publish_jobs WHERE status='published'
    )
  RETURNING id;
"
```

This invalidates every approved-but-not-yet-published approval. Use sparingly. Coordinate before flipping — this also blocks the next `outreach-manual-publish` tick from sending DMs for those approvals (the SELECT already filters on `expires_at > now()`).

## Verifying revocation took effect

Try to insert a fake `publish_jobs` row referencing the revoked approval. It should fail at the trigger:

```bash
psql "$ADMIN_URL" -c "
  BEGIN;
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
  SELECT id, 'test', 'test', 'manual_required', approved_content_hash
  FROM approvals WHERE id = <APPROVAL_ID>;
  ROLLBACK;
"
```

Expected error: `ERROR: approval has expired (expires_at=... now=...)`.

If the insert *succeeds* (which would only happen if you typo'd the approval id or revoked the wrong row), the trigger is healthy but you targeted the wrong approval — redo with the correct id.

## What revocation does NOT do

- Doesn't delete the row from `approvals` — audit trail stays.
- Doesn't undo any publish_jobs already in `status='published'` — those are out the door already.
- Doesn't re-enable the draft for re-approval; the chosen draft is still `status='approved'` and its siblings are still `status='rejected'`. If you need to re-review, you'll need to manually flip statuses back via SQL.

## Recovering from a wrongly-revoked approval

If you revoked the wrong row, just push `expires_at` back into the future:

```bash
psql "$ADMIN_URL" -c "
  UPDATE approvals
  SET expires_at = approved_at + INTERVAL '7 days',
      approval_notes = COALESCE(approval_notes,'') || ' [revocation reversed at ' || now()::text || ']'
  WHERE id = <APPROVAL_ID>;
"
```

The 7-day window is the original TTL set in the migration. Adjust if the approval should expire sooner.
