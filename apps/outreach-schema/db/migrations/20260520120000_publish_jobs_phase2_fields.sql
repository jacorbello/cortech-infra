-- migrate:up
ALTER TABLE publish_jobs
  ADD COLUMN attempt_count INT NOT NULL DEFAULT 0,
  ADD COLUMN sent_at TIMESTAMPTZ;

-- migrate:down
ALTER TABLE publish_jobs
  DROP COLUMN sent_at,
  DROP COLUMN attempt_count;
