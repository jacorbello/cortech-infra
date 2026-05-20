#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

PUBLISH_JOB_ID=""

cleanup() {
  if [ -n "$PUBLISH_JOB_ID" ]; then
    psql "$ADMIN_URL" -c "DELETE FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== T21a: Workflow D retry_cap test ==="

# Find a known-good approved approval (skip 21 and 20 which have hash mismatches)
APPROVAL_ID=$(psql "$ADMIN_URL" -tAc "SELECT id FROM approvals WHERE decision='approved' AND id NOT IN (21,20) ORDER BY id DESC LIMIT 1;")
[ -z "$APPROVAL_ID" ] && { echo "FAIL: no approved approval available"; exit 1; }
HASH=$(psql "$ADMIN_URL" -tAc "SELECT approved_content_hash FROM approvals WHERE id=$APPROVAL_ID;")
echo "Using approval $APPROVAL_ID with hash $HASH"

echo "Setup: insert row with attempt_count=3 (above the < 3 cap)"
PUBLISH_JOB_ID=$(psql "$ADMIN_URL" -tAc "
  BEGIN;
  ALTER TABLE publish_jobs DISABLE TRIGGER trg_enforce_approval_match;
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash, status, attempt_count)
  VALUES ($APPROVAL_ID, 'test-retry-cap', 'cap-test', 'postiz_scheduled', '$HASH', 'ready', 3)
  RETURNING id;
  ALTER TABLE publish_jobs ENABLE TRIGGER trg_enforce_approval_match;
  COMMIT;
" 2>&1 | grep -E '^[0-9]+$')

if [ -z "$PUBLISH_JOB_ID" ]; then
  echo "FAIL: could not insert synthetic publish_jobs row"
  exit 1
fi
echo "Synthetic row id=$PUBLISH_JOB_ID, attempt_count=3"

echo "Wait 3 min — Workflow D should NOT touch this row (Fetch Ready filters attempt_count < 3)..."
sleep 180

STATUS=$(psql "$ADMIN_URL" -tAc "SELECT status FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
ATTEMPTS=$(psql "$ADMIN_URL" -tAc "SELECT attempt_count FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
echo "status='$STATUS' attempt_count=$ATTEMPTS"

if [ "$STATUS" != "ready" ] || [ "$ATTEMPTS" != "3" ]; then
  echo "FAIL: expected status='ready' attempt_count=3, got status='$STATUS' attempt_count=$ATTEMPTS"
  exit 1
fi

echo "PASS: Workflow D respected the retry cap — row with attempt_count=3 was not picked up"

echo "Cleanup: deleting synthetic row (via trap)"

echo "=== T21a ALL TESTS PASS ==="
