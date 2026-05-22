-- migrate:up
ALTER TABLE outcomes ALTER COLUMN publish_job_id DROP NOT NULL;

-- migrate:down
DELETE FROM outcomes WHERE publish_job_id IS NULL;
ALTER TABLE outcomes ALTER COLUMN publish_job_id SET NOT NULL;
