-- migrate:up
CREATE TABLE outreach_items (
  id              BIGSERIAL PRIMARY KEY,
  source_platform TEXT NOT NULL CHECK (source_platform IN ('manual','rss','reddit','x','bluesky','mastodon','google_alerts')),
  source_url      TEXT NOT NULL,
  source_excerpt  TEXT,
  source_author   TEXT,
  source_community TEXT,
  topic           TEXT,
  persona         TEXT,
  intent_score    SMALLINT CHECK (intent_score BETWEEN 0 AND 100),
  risk_score      SMALLINT CHECK (risk_score BETWEEN 0 AND 100),
  status          TEXT NOT NULL DEFAULT 'discovered'
                    CHECK (status IN ('discovered','drafting','drafted','reviewed','rejected','archived')),
  discovered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_platform, source_url)
);
CREATE INDEX idx_outreach_items_status_discovered_at ON outreach_items (status, discovered_at);

-- migrate:down
DROP TABLE outreach_items;
