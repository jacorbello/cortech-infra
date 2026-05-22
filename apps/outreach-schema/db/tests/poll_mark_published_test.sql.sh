# poll_mark_published_test.sql.sh — sourced from run_tests.sh.
#
# Pins the Mark Published CTE used by the outreach-publish-poll workflow:
#   1. Idempotence: running the CTE twice on the same row mutates only once.
#   2. No-demote: when outreach_items.status='rejected' (operator hand-rejected
#      after the publish_job was dispatched), the CTE flips publish_jobs but
#      MUST NOT promote outreach_items back to 'published'.

echo ""
echo "--- poll_mark_published_test.sql.sh ---"

# Test 1: Idempotence. Run Mark Published twice on the same publish_jobs row.
# The second run should be a no-op (UPDATE matches 0 rows; outcomes INSERT
# matches 0 rows via the WHERE EXISTS / FROM pj_update guard).
run_expect_pass "Mark Published CTE: idempotent on second invocation" "
    WITH oi AS (
      INSERT INTO outreach_items (source_platform, source_url, status)
      VALUES ('manual', 'https://example.com/idem-' || extract(epoch from now())::text, 'reviewed')
      RETURNING id
    ),
    dr AS (
      INSERT INTO drafts (outreach_item_id, variant, model_provider, model_name, prompt_version, draft_text, suggested_destination, suggested_post_type, content_hash, status)
      SELECT id, 'helpful_only', 'anthropic', 'claude-sonnet-4-6', 'draft-v1', 'idem test draft', 'x_post', 'thread', 'idem-hash', 'approved' FROM oi
      RETURNING id
    ),
    ap AS (
      INSERT INTO approvals (draft_id, approved_by, decision, approved_content_hash, approved_destination, approved_post_type, approved_platform, edited_text)
      SELECT id, 'jeremy', 'approved', 'idem-hash', 'idem-dest', 'reply', 'bluesky', 'idem test draft' FROM dr
      RETURNING id
    ),
    pj AS (
      INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, status, postiz_post_id, sent_at, payload_hash)
      SELECT id, 'bluesky', 'idem-dest', 'postiz_immediate', 'sent_to_postiz', 'idem-postiz-id', now(), 'idem-hash' FROM ap
      RETURNING id
    )
    SELECT id INTO TEMP TABLE tmp_pj FROM pj;

    -- First invocation: mutates.
    WITH pj_update AS (
      UPDATE publish_jobs
         SET status='published', published_at=now(), published_url='https://bsky.app/idem'
       WHERE id=(SELECT id FROM tmp_pj) AND status='sent_to_postiz' AND published_at IS NULL
      RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id
    ), oi_update AS (
      UPDATE outreach_items SET status='published'
       WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed'
      RETURNING id
    )
    INSERT INTO outcomes (publish_job_id, notes)
    SELECT id, jsonb_build_object('kind','publish_confirmed')::text FROM pj_update;

    DO \$\$
    DECLARE r_pj_status TEXT; r_oi_status TEXT; r_outcomes INT;
    BEGIN
      SELECT status INTO r_pj_status FROM publish_jobs WHERE id = (SELECT id FROM tmp_pj);
      SELECT oi.status INTO r_oi_status FROM outreach_items oi
        JOIN drafts d ON d.outreach_item_id = oi.id
        JOIN approvals a ON a.draft_id = d.id
        JOIN publish_jobs pj ON pj.approval_id = a.id WHERE pj.id = (SELECT id FROM tmp_pj);
      SELECT COUNT(*) INTO r_outcomes FROM outcomes WHERE publish_job_id = (SELECT id FROM tmp_pj);
      IF r_pj_status <> 'published' THEN RAISE EXCEPTION 'pj status after run 1 = %', r_pj_status; END IF;
      IF r_oi_status <> 'published' THEN RAISE EXCEPTION 'oi status after run 1 = %', r_oi_status; END IF;
      IF r_outcomes <> 1 THEN RAISE EXCEPTION 'outcomes count after run 1 = %', r_outcomes; END IF;
    END
    \$\$;

    -- Second invocation: must be a no-op.
    WITH pj_update AS (
      UPDATE publish_jobs
         SET status='published', published_at=now(), published_url='https://bsky.app/idem2'
       WHERE id=(SELECT id FROM tmp_pj) AND status='sent_to_postiz' AND published_at IS NULL
      RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id
    ), oi_update AS (
      UPDATE outreach_items SET status='published'
       WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed'
      RETURNING id
    )
    INSERT INTO outcomes (publish_job_id, notes)
    SELECT id, jsonb_build_object('kind','publish_confirmed')::text FROM pj_update;

    DO \$\$
    DECLARE r_outcomes INT;
    BEGIN
      SELECT COUNT(*) INTO r_outcomes FROM outcomes WHERE publish_job_id = (SELECT id FROM tmp_pj);
      IF r_outcomes <> 1 THEN RAISE EXCEPTION 'outcomes count after run 2 = % (expected idempotent no-op)', r_outcomes; END IF;
    END
    \$\$;
"

# Test 2: No-demote. outreach_items.status='rejected' must remain 'rejected'
# even though the CTE flips publish_jobs to 'published'.
run_expect_pass "Mark Published CTE: never promotes outreach_items from rejected" "
    WITH oi AS (
      INSERT INTO outreach_items (source_platform, source_url, status)
      VALUES ('manual', 'https://example.com/reject-' || extract(epoch from now())::text, 'rejected')
      RETURNING id
    ),
    dr AS (
      INSERT INTO drafts (outreach_item_id, variant, model_provider, model_name, prompt_version, draft_text, suggested_destination, suggested_post_type, content_hash, status)
      SELECT id, 'helpful_only', 'anthropic', 'claude-sonnet-4-6', 'draft-v1', 'reject test draft', 'x_post', 'thread', 'reject-hash', 'approved' FROM oi
      RETURNING id
    ),
    ap AS (
      INSERT INTO approvals (draft_id, approved_by, decision, approved_content_hash, approved_destination, approved_post_type, approved_platform, edited_text)
      SELECT id, 'jeremy', 'approved', 'reject-hash', 'reject-dest', 'reply', 'bluesky', 'reject test draft' FROM dr
      RETURNING id
    ),
    pj AS (
      INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, status, postiz_post_id, sent_at, payload_hash)
      SELECT id, 'bluesky', 'reject-dest', 'postiz_immediate', 'sent_to_postiz', 'reject-postiz-id', now(), 'reject-hash' FROM ap
      RETURNING id
    )
    SELECT id INTO TEMP TABLE tmp_pj_reject FROM pj;

    WITH pj_update AS (
      UPDATE publish_jobs
         SET status='published', published_at=now(), published_url='https://bsky.app/reject'
       WHERE id=(SELECT id FROM tmp_pj_reject) AND status='sent_to_postiz' AND published_at IS NULL
      RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id
    ), oi_update AS (
      UPDATE outreach_items SET status='published'
       WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed'
      RETURNING id
    )
    INSERT INTO outcomes (publish_job_id, notes)
    SELECT id, jsonb_build_object('kind','publish_confirmed')::text FROM pj_update;

    DO \$\$
    DECLARE r_pj_status TEXT; r_oi_status TEXT;
    BEGIN
      SELECT status INTO r_pj_status FROM publish_jobs WHERE id = (SELECT id FROM tmp_pj_reject);
      SELECT oi.status INTO r_oi_status FROM outreach_items oi
        JOIN drafts d ON d.outreach_item_id = oi.id
        JOIN approvals a ON a.draft_id = d.id
        JOIN publish_jobs pj ON pj.approval_id = a.id WHERE pj.id = (SELECT id FROM tmp_pj_reject);
      IF r_pj_status <> 'published' THEN RAISE EXCEPTION 'pj status = %', r_pj_status; END IF;
      IF r_oi_status <> 'rejected' THEN RAISE EXCEPTION 'oi was promoted from rejected to %', r_oi_status; END IF;
    END
    \$\$;
"
