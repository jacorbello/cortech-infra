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
#
# Negative tests must specify the expected SQLSTATE. Without that pin, any error during the
# test (NOT NULL violations, FK violations, CHECK violations, typos) silently passes as
# "expected EXCEPTION" — that masked B1's NOT NULL constraint addition until B8 fixup.
#
# Common SQLSTATEs we use:
#   P0001 — PL/pgSQL RAISE EXCEPTION (enforce_approval_match trigger)
#   23502 — NOT NULL violation
#   23503 — foreign key violation
#   23505 — unique violation
#   23514 — CHECK constraint violation
# Full list: https://www.postgresql.org/docs/current/errcodes-appendix.html
#
# VERBOSITY=verbose makes psql print errors as "ERROR:  <SQLSTATE>: <message>" so we can
# grep the SQLSTATE class. ON_ERROR_STOP=1 ensures multi-statement scripts bail at the
# first error rather than continuing past it.

PSQL_FLAGS=(-X -v VERBOSITY=verbose -v ON_ERROR_STOP=1)
FAILURES=0

run_expect_fail() {
  local label="$1"
  local expected_sqlstate="$2"
  local sql="$3"
  local out
  if out=$(echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" "${PSQL_FLAGS[@]}" 2>&1); then
    echo "FAIL: $label — expected EXCEPTION with SQLSTATE $expected_sqlstate, got success"
    FAILURES=$((FAILURES + 1))
  elif ! grep -qE "^ERROR:[[:space:]]+${expected_sqlstate}:" <<< "$out"; then
    echo "FAIL: $label — got an error, but SQLSTATE was not $expected_sqlstate"
    echo "  Actual output:"
    sed 's/^/    /' <<< "$out"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: $label"
  fi
}

run_expect_pass() {
  local label="$1"
  local sql="$2"
  local out
  if out=$(echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" "${PSQL_FLAGS[@]}" 2>&1); then
    echo "PASS: $label"
  else
    echo "FAIL: $label — expected success, got error"
    echo "  Actual output:"
    sed 's/^/    /' <<< "$out"
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
