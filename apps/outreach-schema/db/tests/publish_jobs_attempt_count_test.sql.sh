#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

echo "Test 1: publish_jobs.attempt_count column exists and defaults to 0"
RESULT=$(psql "$ADMIN_URL" -tAc "
  WITH ins AS (
    INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    SELECT id, 'test_phase2_ac', 'test_phase2_ac', 'manual_required', approved_content_hash
    FROM approvals WHERE decision='approved' LIMIT 1
    RETURNING attempt_count
  )
  SELECT attempt_count FROM ins;
")
psql "$ADMIN_URL" -c "DELETE FROM publish_jobs WHERE destination_platform='test_phase2_ac';" >/dev/null
if [ "$RESULT" != "0" ]; then
  echo "FAIL: expected attempt_count=0, got '$RESULT'"
  exit 1
fi
echo "PASS: attempt_count defaults to 0"

echo "Test 2: publish_jobs.sent_at column exists and is nullable"
RESULT=$(psql "$ADMIN_URL" -tAc "
  SELECT is_nullable FROM information_schema.columns
  WHERE table_name='publish_jobs' AND column_name='sent_at';
")
if [ "$RESULT" != "YES" ]; then
  echo "FAIL: expected sent_at nullable=YES, got '$RESULT'"
  exit 1
fi
echo "PASS: sent_at is nullable"

echo "All tests PASS"
