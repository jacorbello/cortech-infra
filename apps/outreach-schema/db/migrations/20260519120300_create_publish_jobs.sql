-- migrate:up
CREATE TABLE publish_jobs (
  id                     BIGSERIAL PRIMARY KEY,
  approval_id            BIGINT NOT NULL REFERENCES approvals(id),
  destination_platform   TEXT NOT NULL,
  destination_account    TEXT NOT NULL,
  postiz_integration_id  TEXT,
  scheduled_for          TIMESTAMPTZ,
  publish_mode           TEXT NOT NULL CHECK (publish_mode IN ('postiz_scheduled','postiz_immediate','manual_required')),
  status                 TEXT NOT NULL DEFAULT 'ready'
                          CHECK (status IN ('ready','sent_to_postiz','scheduled','published','manual_post_required','failed','expired')),
  postiz_post_id         TEXT,
  published_url          TEXT,
  published_at           TIMESTAMPTZ,
  failure_reason         TEXT,
  payload_hash           TEXT NOT NULL
);
CREATE INDEX idx_publish_jobs_status_scheduled ON publish_jobs (status, scheduled_for);

-- migrate:down
DROP TABLE publish_jobs;
