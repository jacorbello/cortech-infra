-- migrate:up
CREATE TABLE drafts (
  id                BIGSERIAL PRIMARY KEY,
  outreach_item_id  BIGINT NOT NULL REFERENCES outreach_items(id),
  variant           TEXT NOT NULL CHECK (variant IN ('helpful_only','founder_context','soft_product')),
  model_provider    TEXT NOT NULL,
  model_name        TEXT NOT NULL,
  prompt_version    TEXT NOT NULL,
  draft_text        TEXT NOT NULL,
  suggested_destination TEXT NOT NULL,
  suggested_post_type   TEXT NOT NULL,
  claims_to_verify  JSONB NOT NULL DEFAULT '[]'::jsonb,
  risk_flags        JSONB NOT NULL DEFAULT '[]'::jsonb,
  risk_score        SMALLINT NOT NULL DEFAULT 50 CHECK (risk_score BETWEEN 0 AND 100),
  manual_only       BOOLEAN NOT NULL DEFAULT false,
  content_hash      TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'needs_human_review'
                      CHECK (status IN ('needs_human_review','approved','rejected','expired')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_drafts_status_created_at ON drafts (status, created_at);

-- migrate:down
DROP TABLE drafts;
