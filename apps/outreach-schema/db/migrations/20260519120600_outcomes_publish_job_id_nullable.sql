-- migrate:up
ALTER TABLE outcomes ALTER COLUMN publish_job_id DROP NOT NULL;

-- migrate:down
ALTER TABLE outcomes ALTER COLUMN publish_job_id SET NOT NULL;
