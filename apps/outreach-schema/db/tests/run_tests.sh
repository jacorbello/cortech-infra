#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL must be set" >&2
  exit 2
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql not on PATH — install postgresql-client" >&2
  exit 2
fi

cd "$(dirname "$0")"

# Wrap each test in a transaction that is rolled back at the end, so tests don't pollute state.
# psql exits non-zero on EXCEPTION inside the transaction; that's what we use to assert.

FAILURES=0

run_expect_fail() {
  local label="$1"
  local sql="$2"
  if echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
    echo "FAIL: $label — expected EXCEPTION, got success"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: $label"
  fi
}

run_expect_pass() {
  local label="$1"
  local sql="$2"
  if echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
    echo "PASS: $label"
  else
    echo "FAIL: $label — expected success, got error"
    echo "  Re-running to capture error:"
    echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 || true
    FAILURES=$((FAILURES + 1))
  fi
}

source ./trigger_enforcement_test.sql.sh

if [[ "$FAILURES" -gt 0 ]]; then
  echo ""
  echo "$FAILURES test(s) failed."
  exit 1
fi
echo ""
echo "All tests passed."
