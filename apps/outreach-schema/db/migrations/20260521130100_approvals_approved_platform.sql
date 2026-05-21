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

-- Safety net for approvals that exist without publish_jobs rows
-- (Phase 1 testing detritus, save_for_later, rejected decisions)
UPDATE approvals SET approved_platform = 'bluesky'
WHERE approved_platform IS NULL;

-- Make NOT NULL after backfill (no rows should be NULL at this point).
ALTER TABLE approvals
  ALTER COLUMN approved_platform SET NOT NULL,
  ADD CONSTRAINT approvals_approved_platform_check
    CHECK (approved_platform IN ('bluesky','mastodon','reddit','x','linkedin'));

-- migrate:down
ALTER TABLE approvals DROP CONSTRAINT approvals_approved_platform_check;
ALTER TABLE approvals DROP COLUMN approved_platform;
