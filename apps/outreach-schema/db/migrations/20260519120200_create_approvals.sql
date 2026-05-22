-- migrate:up
CREATE TABLE approvals (
  id                       BIGSERIAL PRIMARY KEY,
  draft_id                 BIGINT NOT NULL REFERENCES drafts(id),
  approved_by              TEXT NOT NULL,
  decision                 TEXT NOT NULL CHECK (decision IN ('approved','rejected','manual_only','save_for_later')),
  edited_text              TEXT,
  approved_destination     TEXT NOT NULL,
  approved_post_type       TEXT NOT NULL,
  approved_content_hash    TEXT NOT NULL,
  approval_notes           TEXT,
  approved_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at               TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '7 days')
);

-- migrate:down
DROP TABLE approvals;
