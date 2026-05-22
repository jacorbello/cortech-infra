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
