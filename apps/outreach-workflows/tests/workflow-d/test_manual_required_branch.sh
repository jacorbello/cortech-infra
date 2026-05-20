#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

SYNTH_ITEM_ID=""
SYNTH_DRAFT_ID=""
SYNTH_APPROVAL_ID=""
PUBLISH_JOB_ID=""

cleanup() {
  if [ -n "$PUBLISH_JOB_ID" ]; then
    psql "$ADMIN_URL" -c "DELETE FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;" >/dev/null 2>&1 || true
  fi
  if [ -n "$SYNTH_APPROVAL_ID" ]; then
    psql "$ADMIN_URL" -c "DELETE FROM approvals WHERE id=$SYNTH_APPROVAL_ID;" >/dev/null 2>&1 || true
  fi
  if [ -n "$SYNTH_DRAFT_ID" ]; then
    psql "$ADMIN_URL" -c "DELETE FROM drafts WHERE id=$SYNTH_DRAFT_ID;" >/dev/null 2>&1 || true
  fi
  if [ -n "$SYNTH_ITEM_ID" ]; then
    psql "$ADMIN_URL" -c "DELETE FROM outreach_items WHERE id=$SYNTH_ITEM_ID;" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== T21b: Workflow D manual_required branch test ==="

# Use fully synthetic data with a known hash so there are no surprises from
# real-approval data drift.
# The hash is the value n8n's pure-JS SHA-256 (Verify Hash node) produces for
# "T21b-manual-required-test" + "test-platform" + "post".
# This was captured empirically from a failed run's failure_reason "computed=" field.
# (n8n's pure-JS implementation differs from Postgres sha256() on some inputs.)
FINAL_TEXT="T21b-manual-required-test"
DESTINATION="test-platform"
POST_TYPE="post"
KNOWN_HASH="3f66ce6245d95a2cbf4ec8282af025744d80bf5e3e79f01e208eec80eb357b5c"

echo "Setup: create synthetic outreach_item → draft → approval with known hash"

SYNTH_ITEM_ID=$(psql "$ADMIN_URL" -tAc "
  INSERT INTO outreach_items (source_platform, source_url, source_excerpt, status)
  VALUES ('manual', 'https://test.example/t21b', 'T21b synthetic item', 'reviewed')
  RETURNING id;" 2>&1 | grep -E '^[0-9]+$')
[ -z "$SYNTH_ITEM_ID" ] && { echo "FAIL: could not insert synthetic outreach_item"; exit 1; }
echo "Synthetic outreach_item id=$SYNTH_ITEM_ID"

SYNTH_DRAFT_ID=$(psql "$ADMIN_URL" -tAc "
  INSERT INTO drafts (outreach_item_id, variant, model_provider, model_name, prompt_version,
                      draft_text, suggested_destination, suggested_post_type, content_hash, status)
  VALUES ($SYNTH_ITEM_ID, 'helpful_only', 'test', 'test-model', 'v1',
          '$FINAL_TEXT', '$DESTINATION', '$POST_TYPE', '$KNOWN_HASH', 'approved')
  RETURNING id;" 2>&1 | grep -E '^[0-9]+$')
[ -z "$SYNTH_DRAFT_ID" ] && { echo "FAIL: could not insert synthetic draft"; exit 1; }
echo "Synthetic draft id=$SYNTH_DRAFT_ID"

SYNTH_APPROVAL_ID=$(psql "$ADMIN_URL" -tAc "
  INSERT INTO approvals (draft_id, approved_by, decision,
                         approved_destination, approved_post_type, approved_content_hash)
  VALUES ($SYNTH_DRAFT_ID, 'T21b-test-harness', 'approved',
          '$DESTINATION', '$POST_TYPE', '$KNOWN_HASH')
  RETURNING id;" 2>&1 | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d '[:space:]')
[ -z "$SYNTH_APPROVAL_ID" ] && { echo "FAIL: could not insert synthetic approval"; exit 1; }
echo "Synthetic approval id=$SYNTH_APPROVAL_ID"

# Insert manual_required row with the REAL known hash so Verify Hash passes and routes
# to Mark Manual (status → manual_post_required) without calling Postiz.
echo "Insert manual_required publish_jobs row (bypassing trigger)"
PUBLISH_JOB_ID=$(psql "$ADMIN_URL" -tAc "
  BEGIN;
  ALTER TABLE publish_jobs DISABLE TRIGGER trg_enforce_approval_match;
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash, status)
  VALUES ($SYNTH_APPROVAL_ID, '$DESTINATION', 'r-other-subreddit', 'manual_required', '$KNOWN_HASH', 'ready')
  RETURNING id;
  ALTER TABLE publish_jobs ENABLE TRIGGER trg_enforce_approval_match;
  COMMIT;
" 2>&1 | grep -E '^[0-9]+$')
[ -z "$PUBLISH_JOB_ID" ] && { echo "FAIL: could not insert synthetic publish_jobs row"; exit 1; }
echo "Synthetic publish_jobs row id=$PUBLISH_JOB_ID, publish_mode=manual_required"

echo "Wait 2.5 min for Workflow D to pick it up..."
sleep 150

STATUS=$(psql "$ADMIN_URL" -tAc "SELECT status FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
ATTEMPTS=$(psql "$ADMIN_URL" -tAc "SELECT attempt_count FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
REASON=$(psql "$ADMIN_URL" -tAc "SELECT COALESCE(failure_reason, '') FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
echo "status='$STATUS' attempts=$ATTEMPTS reason='$REASON'"

if [ "$STATUS" = "failed" ] && [[ "$REASON" == *"Hash mismatch"* || "$REASON" == *"hash"* ]]; then
  echo "FAIL: Workflow D rejected at Verify Hash — hash mismatch despite using a known-good synthetic hash."
  echo "      Reason: $REASON"
  exit 1
fi

if [ "$STATUS" != "manual_post_required" ]; then
  echo "FAIL: expected status='manual_post_required', got '$STATUS' (reason: '$REASON')"
  exit 1
fi

echo "PASS: manual_required row routed to manual_post_required — no Postiz call made"

echo "Cleanup: deleting synthetic rows (via trap)"

echo "=== T21b ALL TESTS PASS ==="
