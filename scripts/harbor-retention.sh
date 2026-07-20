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
#   RETAIN_KEEP    (default "{stable*,latest*,buildcache}" — globs the retention
#                   policy ALWAYS keeps, on top of the recent-K per-SHA tags)
#   IMMUTABLE_KEEP (default "" — glob for an immutable-tag rule; EMPTY = disabled.
#                   Do NOT point at :stable-homelab/:latest: they are re-pushed
#                   every build and immutability blocks overwrite, breaking the
#                   deploy. Use only a dedicated frozen promotion tag.)

HARBOR_URL="${HARBOR_URL:-https://harbor.corbello.io}"
HARBOR_PROJECT="${HARBOR_PROJECT:-plotlens}"
HARBOR_USER="${HARBOR_USER:-admin}"
RETAIN_K="${RETAIN_K:-10}"
RETAIN_CRON="${RETAIN_CRON:-0 0 3 * * *}"
RETAIN_KEEP="${RETAIN_KEEP:-{stable*,latest*,buildcache\}}"
IMMUTABLE_KEEP="${IMMUTABLE_KEEP:-}"

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
    --arg keep "$RETAIN_KEEP" \
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

build_immutable() { # $1=tag glob -> POST body for an immutable-tag rule
  jq -n --arg keep "$1" '
    { disabled: false,
      scope_selectors: { repository: [ { kind: "doublestar", decoration: "repoMatches", pattern: "**" } ] },
      tag_selectors: [ { kind: "doublestar", decoration: "matches", pattern: $keep } ] }
  '
}

# ---- response split: separates the trailing HTTP code from the body ---------
# req() runs in a $(...) subshell, so it CANNOT set globals directly; instead it
# prints "<code>\n<body>" and _split (run in the caller) populates the globals.
REQ_CODE=""
REQ_BODY=""
_split() { # $1 = raw "code\nbody"
  local raw="$1"
  if [[ "$raw" == *$'\n'* ]]; then
    REQ_CODE="${raw%%$'\n'*}"; REQ_BODY="${raw#*$'\n'}"
  else
    REQ_CODE="$raw"; REQ_BODY=""
  fi
}

# ---- offline self-check: fails if the JSON builders or split logic drift -----
if [ "${1:-}" = "--selftest" ]; then
  r="$(build_retention 42 7)"
  echo "$r" | jq -e '.scope.ref == 42 and .id == 7 and .algorithm == "or"
    and (.rules | length == 2)
    and (.rules[0].params.latestPushedK == 10)
    and (.rules[1].template == "always")' >/dev/null \
    || { echo "SELFTEST FAIL: retention payload"; echo "$r" | jq .; exit 1; }
  build_immutable "stable-frozen" | jq -e '.tag_selectors[0].pattern == "stable-frozen" and .disabled == false' >/dev/null \
    || { echo "SELFTEST FAIL: immutable payload"; exit 1; }
  _split "$(printf '200\n{"x":1}')"
  if [ "$REQ_CODE" != "200" ] || [ "$REQ_BODY" != '{"x":1}' ]; then
    echo "SELFTEST FAIL: split code/body (code=$REQ_CODE body=$REQ_BODY)"; exit 1
  fi
  _split "204"
  if [ "$REQ_CODE" != "204" ] || [ -n "$REQ_BODY" ]; then
    echo "SELFTEST FAIL: split empty body (code=$REQ_CODE body=$REQ_BODY)"; exit 1
  fi
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

# ---- HTTP: prints "<code>\n<body>"; never logs creds. Pair with _split. -----
req() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}" tmp code
  local -a args=(-sS -u "${HARBOR_USER}:${HARBOR_PASS}"
    -H "Content-Type: application/json" -X "$method" -w '%{http_code}')
  [ -n "$body" ] && args+=(--data-binary "$body")
  tmp="$(mktemp)"
  code="$(curl "${args[@]}" -o "$tmp" "${HARBOR_URL}/api/v2.0${path}")" || {
    rm -f "$tmp"; echo "curl failed: $method $path" >&2; exit 5; }
  printf '%s\n' "$code"
  cat "$tmp"
  rm -f "$tmp"
}
_R() { _split "$(req "$@")"; } # convenience: run req + populate REQ_CODE/REQ_BODY

die_bad() { # $1=code $2=context $3=body
  case "$1" in
    2*) return 0 ;;
    *) echo "Harbor API error ($1) during $2:" >&2; echo "$3" >&2; exit 6 ;;
  esac
}

echo "== Harbor ${HARBOR_URL}  project=${HARBOR_PROJECT}  (dry-run=${DRY_RUN}) =="

_R GET "/projects/${HARBOR_PROJECT}"; die_bad "$REQ_CODE" "get project" "$REQ_BODY"
PID="$(echo "$REQ_BODY" | jq -r '.project_id')"
RID="$(echo "$REQ_BODY" | jq -r '.metadata.retention_id // empty')"
echo "project_id=${PID}  existing_retention_id=${RID:-none}"

# ---- retention --------------------------------------------------------------
render() { jq '{algorithm, rules: [.rules[] | {template, params, tag: .tag_selectors[0].pattern}], trigger}'; }

# A project can carry a non-zero retention_id whose policy was since deleted
# (Harbor leaves the ref dangling). Only take the update path if the GET
# actually resolves; otherwise fall through and create a fresh policy.
do_update=0
if [ -n "${RID:-}" ] && [ "$RID" != "0" ]; then
  _R GET "/retentions/${RID}"
  if [[ "$REQ_CODE" == 2* ]]; then
    do_update=1
    echo "-- current retention policy (id ${RID}) --"; echo "$REQ_BODY" | render
  else
    echo "note: project metadata has retention_id ${RID} but GET returned ${REQ_CODE}; treating as stale — will create a fresh policy"
  fi
fi

if [ "$do_update" -eq 1 ]; then
  body="$(build_retention "$PID" "$RID")"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "-- would PUT /retentions/${RID} --"; echo "$body" | render
  else
    _R PUT "/retentions/${RID}" "$body"; die_bad "$REQ_CODE" "update retention" "$REQ_BODY"
    echo "retention policy ${RID} updated (${REQ_CODE})"
  fi
else
  body="$(build_retention "$PID")"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "-- would POST /retentions (no valid existing policy) --"; echo "$body" | render
  else
    _R POST "/retentions" "$body"; die_bad "$REQ_CODE" "create retention" "$REQ_BODY"
    echo "retention policy created (${REQ_CODE})"
  fi
fi

# ---- immutability (opt-in; OFF by default) ----------------------------------
# Immutability blocks overwrite as well as delete, so it must never target the
# moving :stable-homelab/:latest tags (re-pushed every build). Enable only for a
# dedicated frozen promotion tag by setting IMMUTABLE_KEEP.
if [ -z "$IMMUTABLE_KEEP" ]; then
  echo "immutability: disabled (IMMUTABLE_KEEP unset) — retention alone protects tags from GC; set IMMUTABLE_KEEP to a frozen-tag glob to enable"
else
  _R GET "/projects/${PID}/immutabletagrules"; die_bad "$REQ_CODE" "list immutable rules" "$REQ_BODY"
  # Harbor returns a JSON `null` (not `[]`) when a project has no rules — guard it.
  have="$(echo "$REQ_BODY" | jq -r --arg keep "$IMMUTABLE_KEEP" \
    '(. // []) | map(select(.tag_selectors[]?.pattern == $keep)) | length')"
  if [ "${have:-0}" -gt 0 ]; then
    echo "immutable rule for '${IMMUTABLE_KEEP}' already present — ok"
  else
    body="$(build_immutable "$IMMUTABLE_KEEP")"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "-- would POST immutable rule --"; echo "$body" | jq '{tag: .tag_selectors[0].pattern, repo: .scope_selectors.repository[0].pattern}'
    else
      _R POST "/projects/${PID}/immutabletagrules" "$body"; die_bad "$REQ_CODE" "create immutable rule" "$REQ_BODY"
      echo "immutable rule for '${IMMUTABLE_KEEP}' created (${REQ_CODE})"
    fi
  fi
fi

echo "== done =="
