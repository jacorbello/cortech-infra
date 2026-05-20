-- migrate:up
ALTER TABLE outreach_items DROP CONSTRAINT outreach_items_status_check;
ALTER TABLE outreach_items ADD CONSTRAINT outreach_items_status_check
  CHECK (status IN ('discovered','drafting','drafted','reviewed','published','rejected','archived'));

-- migrate:down
ALTER TABLE outreach_items DROP CONSTRAINT outreach_items_status_check;
ALTER TABLE outreach_items ADD CONSTRAINT outreach_items_status_check
  CHECK (status IN ('discovered','drafting','drafted','reviewed','rejected','archived'));
