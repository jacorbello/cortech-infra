#!/usr/bin/env bash
set -Eeuo pipefail

# harbor-retention.sh — enforce tag-retention + immutability on the Harbor
# `plotlens` project so an in-use image tag can never be garbage-collected.
#
# Root cause it fixes: Harbor GC removed per-SHA tags that were still the
# deployed tags (plotlens-realtime, frontend/website/word-addin), causing two
# homelab incidents during the SRE audit (Family-Friendly-Inc/plotlens#5888).
# The permanent, registry-side guardrail is a retention policy that always
# keeps the recent-K per-SHA tags plus every :stable*/:latest* pin, and an
# immutability rule so a bad push can't overwrite the known-good fallback.
#
# Idempotent: enforces desired state. Safe to re-run. Never prints credentials.
#
# Usage (run on the Proxmox master, where kubectl reaches the cluster):
#   ssh root@192.168.1.52 "bash /tmp/harbor-retention.sh --dry-run"   # preview
#   ssh root@192.168.1.52 "bash /tmp/harbor-retention.sh"             # apply
#   bash harbor-retention.sh --selftest                               # offline check
#
# Config via env (all optional):
#   HARBOR_URL     (default https://harbor.corbello.io)
#   HARBOR_PROJECT (default plotlens)
#   HARBOR_USER    (default admin)
#   HARBOR_PASS    (default: read from k8s secret harbor/harbor-core)
#   RETAIN_K       (default 10 — most-recent per-SHA tags kept per repo)
#   RETAIN_CRON    (default "0 0 3 * * *" — Harbor 6-field cron, daily 03:00)
#   ALWAYS_KEEP    (default "{stable*,latest*}" — glob never pruned/mutable)

HARBOR_URL="${HARBOR_URL:-https://harbor.corbello.io}"
HARBOR_PROJECT="${HARBOR_PROJECT:-plotlens}"
HARBOR_USER="${HARBOR_USER:-admin}"
RETAIN_K="${RETAIN_K:-10}"
RETAIN_CRON="${RETAIN_CRON:-0 0 3 * * *}"
ALWAYS_KEEP="${ALWAYS_KEEP:-{stable*,latest*\}}"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --selftest) : ;; # handled below, before any network/cluster access
  "") : ;;
  *) echo "unknown arg: $1 (use --dry-run, --selftest, or no arg to apply)" >&2; exit 2 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 3; }; }
need jq
need curl

# ---- payload builders (pure functions of args; no I/O) ----------------------
build_retention() { # $1=project_id  [$2=existing_retention_id]
  local pid="$1" rid="${2:-}"
  jq -n \
    --argjson pid "$pid" \
    --argjson k "$RETAIN_K" \
    --arg cron "$RETAIN_CRON" \
    --arg keep "$ALWAYS_KEEP" \
    --arg rid "$rid" '
    {
      algorithm: "or",
      rules: [
        { disabled: false, action: "retain", template: "latestPushedK",
          params: { latestPushedK: $k },
          tag_selectors: [ { kind: "doublestar", decoration: "matches", pattern: "**" } ],
          scope_selectors: { repository: [ { kind: "doublestar", decoration: "repoMatches", pattern: "**" } ] } },
        { disabled: false, action: "retain", template: "always",
          params: {},
          tag_selectors: [ { kind: "doublestar", decoration: "matches", pattern: $keep } ],
          scope_selectors: { repository: [ { kind: "doublestar", decoration: "repoMatches", pattern: "**" } ] } }
      ],
      trigger: { kind: "Schedule", settings: { cron: $cron } },
      scope: { level: "project", ref: $pid }
    }
    | if ($rid | length) > 0 then . + { id: ($rid | tonumber) } else . end
  '
}

build_immutable() { # -> POST body for an immutable-tag rule on ALWAYS_KEEP
  jq -n --arg keep "$ALWAYS_KEEP" '
    { disabled: false,
      scope_selectors: { repository: [ { kind: "doublestar", decoration: "repoMatches", pattern: "**" } ] },
      tag_selectors: [ { kind: "doublestar", decoration: "matches", pattern: $keep } ] }
  '
}

# ---- offline self-check: fails if the JSON builders drift -------------------
if [ "${1:-}" = "--selftest" ]; then
  r="$(build_retention 42 7)"
  echo "$r" | jq -e '.scope.ref == 42 and .id == 7 and .algorithm == "or"
    and (.rules | length == 2)
    and (.rules[0].params.latestPushedK == 10)
    and (.rules[1].template == "always")' >/dev/null \
    || { echo "SELFTEST FAIL: retention payload"; echo "$r" | jq .; exit 1; }
  build_immutable | jq -e '.tag_selectors[0].pattern != "" and .disabled == false' >/dev/null \
    || { echo "SELFTEST FAIL: immutable payload"; exit 1; }
  echo "SELFTEST OK"
  exit 0
fi

# ---- credentials (never echoed) --------------------------------------------
if [ -z "${HARBOR_PASS:-}" ]; then
  need kubectl
  HARBOR_PASS="$(kubectl -n harbor get secret harbor-core \
    -o go-template='{{ index .data "HARBOR_ADMIN_PASSWORD" | base64decode }}' 2>/dev/null || true)"
  if [ -z "${HARBOR_PASS:-}" ]; then
    echo "could not read admin password from secret harbor/harbor-core; set HARBOR_PASS" >&2
    exit 4
  fi
fi

# ---- HTTP helper: prints body, sets REQ_CODE; never logs creds -------------
REQ_CODE=""
req() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}" out code
  local -a args=(-sS -u "${HARBOR_USER}:${HARBOR_PASS}"
    -H "Content-Type: application/json" -X "$method" -w $'\n%{http_code}')
  [ -n "$body" ] && args+=(--data-binary "$body")
  out="$(curl "${args[@]}" "${HARBOR_URL}/api/v2.0${path}")" || {
    echo "curl failed: $method $path" >&2; exit 5; }
  code="$(printf '%s' "$out" | tail -n1)"
  REQ_CODE="$code"
  printf '%s' "$out" | sed '$d'
}

die_bad() { # $1=code $2=context $3=body
  case "$1" in
    2*) return 0 ;;
    *) echo "Harbor API error ($1) during $2:" >&2; echo "$3" >&2; exit 6 ;;
  esac
}

echo "== Harbor ${HARBOR_URL}  project=${HARBOR_PROJECT}  (dry-run=${DRY_RUN}) =="

proj="$(req GET "/projects/${HARBOR_PROJECT}")"; die_bad "$REQ_CODE" "get project" "$proj"
PID="$(echo "$proj" | jq -r '.project_id')"
RID="$(echo "$proj" | jq -r '.metadata.retention_id // empty')"
echo "project_id=${PID}  existing_retention_id=${RID:-none}"

# ---- retention --------------------------------------------------------------
render() { jq '{algorithm, rules: [.rules[] | {template, params, tag: .tag_selectors[0].pattern}], trigger}'; }

# A project can carry a non-zero retention_id whose policy was since deleted
# (Harbor leaves the ref dangling). Only take the update path if the GET
# actually resolves; otherwise fall through and create a fresh policy.
do_update=0
if [ -n "${RID:-}" ] && [ "$RID" != "0" ]; then
  cur="$(req GET "/retentions/${RID}")"
  if [[ "$REQ_CODE" == 2* ]]; then
    do_update=1
    echo "-- current retention policy (id ${RID}) --"; echo "$cur" | render
  else
    echo "note: project metadata has retention_id ${RID} but GET returned ${REQ_CODE}; treating as stale — will create a fresh policy"
  fi
fi

if [ "$do_update" -eq 1 ]; then
  body="$(build_retention "$PID" "$RID")"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "-- would PUT /retentions/${RID} --"; echo "$body" | render
  else
    resp="$(req PUT "/retentions/${RID}" "$body")"; die_bad "$REQ_CODE" "update retention" "$resp"
    echo "retention policy ${RID} updated (${REQ_CODE})"
  fi
else
  body="$(build_retention "$PID")"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "-- would POST /retentions (no valid existing policy) --"; echo "$body" | render
  else
    resp="$(req POST "/retentions" "$body")"; die_bad "$REQ_CODE" "create retention" "$resp"
    echo "retention policy created (${REQ_CODE})"
  fi
fi

# ---- immutability -----------------------------------------------------------
rules="$(req GET "/projects/${PID}/immutabletagrules")"; die_bad "$REQ_CODE" "list immutable rules" "$rules"
# Harbor returns a JSON `null` (not `[]`) when a project has no rules — guard it.
have="$(echo "$rules" | jq -r --arg keep "$ALWAYS_KEEP" \
  '(. // []) | map(select(.tag_selectors[]?.pattern == $keep)) | length')"
if [ "${have:-0}" -gt 0 ]; then
  echo "immutable rule for '${ALWAYS_KEEP}' already present — ok"
else
  body="$(build_immutable)"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "-- would POST immutable rule --"; echo "$body" | jq '{tag: .tag_selectors[0].pattern, repo: .scope_selectors.repository[0].pattern}'
  else
    resp="$(req POST "/projects/${PID}/immutabletagrules" "$body")"; die_bad "$REQ_CODE" "create immutable rule" "$resp"
    echo "immutable rule for '${ALWAYS_KEEP}' created (${REQ_CODE})"
  fi
fi

echo "== done =="
