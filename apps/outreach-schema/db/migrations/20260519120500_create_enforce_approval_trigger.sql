-- migrate:up
CREATE OR REPLACE FUNCTION enforce_approval_match() RETURNS trigger AS $$
DECLARE a approvals%ROWTYPE;
BEGIN
  SELECT * INTO a FROM approvals WHERE id = NEW.approval_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'publish_job approval_id=% not found', NEW.approval_id;
  END IF;
  IF a.decision <> 'approved' THEN
    RAISE EXCEPTION 'publish_job approval_id=% has decision=%, must be approved', NEW.approval_id, a.decision;
  END IF;
  IF a.expires_at < now() THEN
    RAISE EXCEPTION 'publish_job approval_id=% expired at %', NEW.approval_id, a.expires_at;
  END IF;
  IF NEW.payload_hash <> a.approved_content_hash THEN
    RAISE EXCEPTION 'publish_job payload_hash does not match approved_content_hash';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_enforce_approval_match
  BEFORE INSERT OR UPDATE OF payload_hash, approval_id ON publish_jobs
  FOR EACH ROW EXECUTE FUNCTION enforce_approval_match();

-- migrate:down
DROP TRIGGER IF EXISTS trg_enforce_approval_match ON publish_jobs;
DROP FUNCTION IF EXISTS enforce_approval_match();
