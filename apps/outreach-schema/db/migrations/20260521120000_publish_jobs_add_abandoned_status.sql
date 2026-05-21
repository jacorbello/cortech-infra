-- migrate:up
ALTER TABLE publish_jobs DROP CONSTRAINT publish_jobs_status_check;
ALTER TABLE publish_jobs ADD CONSTRAINT publish_jobs_status_check
  CHECK (status IN ('ready','sent_to_postiz','scheduled','published','manual_post_required','failed','expired','abandoned'));

-- migrate:down
ALTER TABLE publish_jobs DROP CONSTRAINT publish_jobs_status_check;
ALTER TABLE publish_jobs ADD CONSTRAINT publish_jobs_status_check
  CHECK (status IN ('ready','sent_to_postiz','scheduled','published','manual_post_required','failed','expired'));
