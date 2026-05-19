# Sourced by run_tests.sh. Each test inserts seed data, attempts the publish_job insert, expects the trigger outcome.

# Common seed used by every test
SEED="
  INSERT INTO outreach_items (source_platform, source_url) VALUES ('manual', 'https://example.com/seed') RETURNING id \gset oi_
  INSERT INTO drafts (outreach_item_id, variant, model_provider, model_name, prompt_version, draft_text, suggested_destination, suggested_post_type, content_hash)
    VALUES (:oi_id, 'helpful_only', 'anthropic', 'claude-sonnet-4-6', 'draft-v1', 'hello world', 'x_post', 'thread', 'abc123') RETURNING id \gset d_
"

# Test 1: rejected decision must block publish_jobs insert
run_expect_fail "rejects publish_job for rejected approval" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash)
    VALUES (:d_id, 'jeremy', 'rejected', 'x_post', 'thread', 'abc123') RETURNING id \gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'abc123');
"

# Test 2: expired approval must block publish_jobs insert
run_expect_fail "rejects publish_job for expired approval" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash, expires_at)
    VALUES (:d_id, 'jeremy', 'approved', 'x_post', 'thread', 'abc123', now() - INTERVAL '1 hour') RETURNING id \gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'abc123');
"

# Test 3: mismatched payload_hash must block publish_jobs insert
run_expect_fail "rejects publish_job with mismatched payload_hash" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash)
    VALUES (:d_id, 'jeremy', 'approved', 'x_post', 'thread', 'abc123') RETURNING id \gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'WRONG_HASH');
"

# Test 4: happy path — approved + unexpired + matching hash → INSERT succeeds
run_expect_pass "accepts publish_job for valid approval" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash)
    VALUES (:d_id, 'jeremy', 'approved', 'x_post', 'thread', 'abc123') RETURNING id \gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'abc123');
"
