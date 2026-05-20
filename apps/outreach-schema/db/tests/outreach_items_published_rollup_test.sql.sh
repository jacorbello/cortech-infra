#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

echo "Test 1: outreach_items.status accepts 'published'"
RESULT=$(psql "$ADMIN_URL" -tAc "
WITH ins AS (
  INSERT INTO outreach_items (source_platform, source_url, status)
  VALUES ('manual', 'https://example.com/published-test-' || extract(epoch from now())::text, 'published')
  RETURNING id, status
), del AS (
  DELETE FROM outreach_items WHERE id IN (SELECT id FROM ins) RETURNING 1
)
SELECT status FROM ins;
" 2>&1)
if [[ "$RESULT" != *"published"* ]]; then
  echo "FAIL: status='published' rejected or test errored: $RESULT"
  exit 1
fi
echo "PASS: outreach_items.status accepts 'published'"

echo "Test 2: status='garbage' still rejected"
set +e
RESULT=$(psql "$ADMIN_URL" -tAc "
  INSERT INTO outreach_items (source_platform, source_url, status)
  VALUES ('manual', 'https://example.com/garbage-test', 'garbage')
  RETURNING status;
" 2>&1)
set -e
if [[ "$RESULT" != *"violates check constraint"* ]]; then
  echo "FAIL: invalid status not rejected: $RESULT"
  exit 1
fi
echo "PASS: invalid status rejected"

echo "All tests PASS"
