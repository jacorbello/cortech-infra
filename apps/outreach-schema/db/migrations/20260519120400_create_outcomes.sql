-- migrate:up
CREATE TABLE outcomes (
  id              BIGSERIAL PRIMARY KEY,
  publish_job_id  BIGINT NOT NULL REFERENCES publish_jobs(id),
  impressions     INT,
  replies         INT,
  clicks          INT,
  signups         INT,
  notes           TEXT,
  captured_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- migrate:down
DROP TABLE outcomes;
