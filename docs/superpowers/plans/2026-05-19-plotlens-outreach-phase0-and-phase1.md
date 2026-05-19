# PlotLens Outreach — Phase 0 + Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Phase 0 (Temporal spike) and Phase 1 (end-to-end approval gate with manual publishing) from the spec at `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md`. End state: drafts flow from discovery → AI drafting → human approval (Slack notify + n8n form) → manual-copy publishing, backed by a DB trigger that hard-rejects unapproved/expired/mismatched publish attempts.

**Architecture:** Phase 0 is a throwaway Temporal Helm deployment to a sandbox namespace; findings inform Phase 2 later. Phase 1 adds: (1) `outreach` Postgres database on existing LXC 114 with five tables + a `publish_jobs` enforcement trigger, (2) three n8n workflows (Discover, Draft, Review) on the existing n8n LXC, (3) a credentials-allowlist audit script enforced in CI, (4) Slack notifications + n8n hosted form for human approval. No Postiz, no Temporal in Phase 1.

**Tech Stack:** Postgres 15+ on LXC 114, dbmate (migration tool), Python 3.11+ + pytest (audit script + tests), n8n (existing on LXC 112), Anthropic Claude Sonnet 4.6 + Haiku 4.5, Slack Web API, GitHub Actions on `cortech-infra-runner` (existing), Helm + K3s + Temporal helm chart (Phase 0 only).

**TDD posture:** Strict TDD for the DB trigger (SQL fixture tests) and the Python audit script (pytest). For n8n workflows — built in the UI and exported as JSON — we use a "build → audit → integration smoke" cycle. The audit script is the unit-level check; the smoke workflow exercises the pipeline end-to-end.

---

## File Structure

**Phase 0 (transient):**
- `docs/runbooks/temporal-spike-findings.md` — created in T2, committed in T3 (only persistent artifact from Phase 0)

**Phase 1 — schema:**
- `apps/outreach-schema/README.md` — how to apply / roll back migrations
- `apps/outreach-schema/dbmate.env.example` — connection-string template
- `apps/outreach-schema/Makefile` — wraps `dbmate up`/`down`/`status` against `outreach` DB
- `apps/outreach-schema/db/migrations/20260519120000_create_outreach_items.sql`
- `apps/outreach-schema/db/migrations/20260519120100_create_drafts.sql`
- `apps/outreach-schema/db/migrations/20260519120200_create_approvals.sql`
- `apps/outreach-schema/db/migrations/20260519120300_create_publish_jobs.sql`
- `apps/outreach-schema/db/migrations/20260519120400_create_outcomes.sql`
- `apps/outreach-schema/db/migrations/20260519120500_create_enforce_approval_trigger.sql`
- `apps/outreach-schema/db/tests/trigger_enforcement_test.sql` — SQL test fixture
- `apps/outreach-schema/db/tests/run_tests.sh` — runner script

**Phase 1 — workflows + prompts:**
- `apps/outreach-workflows/README.md` — how workflows export/import, where to edit
- `apps/outreach-workflows/credentials-matrix.yaml` — declarative allowlist of credentials per workflow
- `apps/outreach-workflows/prompts/draft-v1.md` — versioned prompt for Workflow B
- `apps/outreach-workflows/prompts/risk-check-v1.md` — versioned prompt for Workflow B's second-pass
- `apps/outreach-workflows/rss-feeds.yaml` — seed list of RSS sources for Workflow A
- `apps/outreach-workflows/n8n/discover.json` — Workflow A export
- `apps/outreach-workflows/n8n/draft.json` — Workflow B export
- `apps/outreach-workflows/n8n/review.json` — Workflow C export
- `apps/outreach-workflows/n8n/manual-publish.json` — Phase 1's Slack-DM publishing
- `apps/outreach-workflows/n8n/expire-stale.json` — daily expiry cron
- `apps/outreach-workflows/n8n/smoke.json` — nightly end-to-end smoke

**Phase 1 — Python audit tooling:**
- `scripts/n8n/__init__.py`
- `scripts/n8n/audit_credentials.py` — audit script
- `tests/n8n/__init__.py`
- `tests/n8n/conftest.py` — pytest fixtures (sample workflow JSON)
- `tests/n8n/test_audit_credentials.py` — pytest tests
- `tests/n8n/fixtures/workflow_compliant.json`
- `tests/n8n/fixtures/workflow_violation.json`

**Phase 1 — CI:**
- `.github/workflows/outreach-ci.yml` — runs dbmate migration up/down + trigger SQL tests + audit-credentials pytest

**Phase 1 — operational docs:**
- `docs/runbooks/credential-audit.md` — running the audit script locally
- `docs/runbooks/outreach-db-recovery.md` — restoring `outreach` DB from MinIO backup
- `docs/runbooks/revoke-approval.md` — how to expire an approval before its `expires_at`

---

## Phase 0 — Temporal Spike

### Task 1: Deploy Temporal to sandbox namespace

**Files:**
- No repo changes in this task (helm install is imperative)

**Context:** Per the spec, this is a throwaway POC. We use raw `helm install`, not ArgoCD. Findings (target resource requests, chart values, gotchas) inform Phase 2's production deploy.

- [ ] **Step 1: SSH to cortech master and create sandbox namespace**

Run:
```bash
ssh root@192.168.1.52 "kubectl create namespace temporal-spike"
```
Expected: `namespace/temporal-spike created`

- [ ] **Step 2: Add the official Temporal Helm repo**

Run:
```bash
ssh root@192.168.1.52 "helm repo add temporal https://go.temporal.io/helm-charts && helm repo update"
```
Expected: repo added; `Update Complete. ⎈Happy Helming!⎈`

- [ ] **Step 3: Install Temporal with Postgres backend, no Cassandra, no ES**

Run (single command):
```bash
ssh root@192.168.1.52 "helm install temporal-spike temporal/temporal \
  --namespace temporal-spike \
  --set server.replicaCount=1 \
  --set cassandra.enabled=false \
  --set elasticsearch.enabled=false \
  --set prometheus.enabled=false \
  --set grafana.enabled=false \
  --set server.config.persistence.default.driver=sql \
  --set server.config.persistence.default.sql.driver=postgres12 \
  --timeout 10m"
```
Expected: `STATUS: deployed`. If Postgres dependency complains, the chart bundles its own postgres subchart — that's fine for spike purposes.

- [ ] **Step 4: Wait for pods to become Ready**

Run:
```bash
ssh root@192.168.1.52 "kubectl -n temporal-spike wait --for=condition=ready pod --all --timeout=600s"
```
Expected: all pods become Ready (frontend, history, matching, worker, web UI, postgres). If a pod is stuck, capture `kubectl describe pod` output for the findings doc.

- [ ] **Step 5: Capture baseline resource usage**

Run:
```bash
ssh root@192.168.1.52 "kubectl -n temporal-spike top pod"
```
Save the output — it goes into the findings runbook in T2.

### Task 2: Run helloworld sample + restart test, capture findings

**Files:**
- Create: `docs/runbooks/temporal-spike-findings.md`

- [ ] **Step 1: Port-forward Temporal frontend to access from cortech master**

Run in a background terminal on the cortech master:
```bash
ssh root@192.168.1.52 "kubectl -n temporal-spike port-forward svc/temporal-spike-frontend 7233:7233 &"
```
Expected: forwarding started. Leave running.

- [ ] **Step 2: Run the official `helloworld` Go sample**

Use the official `samples-go` repo's helloworld via a one-off pod:
```bash
ssh root@192.168.1.52 "kubectl -n temporal-spike run helloworld-test \
  --rm -i --tty --restart=Never \
  --image=temporaliotest/samples-go-helloworld:latest \
  --env=TEMPORAL_HOST_PORT=temporal-spike-frontend:7233 \
  --env=TEMPORAL_NAMESPACE=default"
```
Expected: workflow completes; output contains `WorkflowResult: Hello World!` or similar. If image doesn't exist, fall back to running the helloworld sample manually with `tctl` (`kubectl exec` into a frontend pod and run `tctl workflow start ...`). Document either path.

- [ ] **Step 3: Restart the Temporal frontend pod to verify state recovery**

Run:
```bash
ssh root@192.168.1.52 "kubectl -n temporal-spike rollout restart deploy/temporal-spike-frontend && \
  kubectl -n temporal-spike rollout status deploy/temporal-spike-frontend --timeout=300s"
```
Expected: deployment restarts successfully. List workflow history afterwards to confirm the prior helloworld run is still present:
```bash
ssh root@192.168.1.52 "kubectl -n temporal-spike exec deploy/temporal-spike-admintools -- \
  tctl --address temporal-spike-frontend:7233 workflow list"
```
Expected: helloworld workflow listed.

- [ ] **Step 4: Write the findings runbook**

Create `docs/runbooks/temporal-spike-findings.md` with this exact structure (fill in the captured numbers):

```markdown
# Temporal Spike Findings (Phase 0)

**Date:** <YYYY-MM-DD>
**Outcome:** GO / NO-GO  ← pick one
**Chart version:** <output of `helm list -n temporal-spike -o json | jq '.[0].chart'`>

## Resource Usage

### At idle (no workflows running)
| Pod | CPU | Memory |
|---|---|---|
| frontend | <m> | <Mi> |
| history | <m> | <Mi> |
| matching | <m> | <Mi> |
| worker | <m> | <Mi> |
| web | <m> | <Mi> |
| postgres | <m> | <Mi> |

### Under helloworld load
(same table with measured values)

## Recommended Production Values

Resource requests to bake into the Phase 2 ArgoCD-managed deploy:
- `server.frontend.resources.requests.cpu: <value>`
- `server.frontend.resources.requests.memory: <value>`
- (repeat for history/matching/worker)
- `postgres.resources.requests.cpu: <value>`
- `postgres.resources.requests.memory: <value>`

## Startup Behavior

- Cold-start time from `helm install` to all-Ready: <minutes>
- Time to recover after `rollout restart`: <seconds>
- State (workflow history) survived restart: yes / no

## K3s-Specific Gotchas

(Anything you hit. Examples: storage class issues, NFS-backed PVC quirks, init container timeouts, network policies, etc.)

## Decision

**Go:** Production Phase 2 should use chart values above + ArgoCD Application + dedicated Postgres on LXC 114 (`temporal` DB).
**No-go:** Reasons listed; alternatives to consider.
```

- [ ] **Step 5: Commit the findings runbook**

```bash
git add docs/runbooks/temporal-spike-findings.md
git commit -m "docs(temporal): add Phase 0 spike findings runbook"
```

### Task 3: Tear down spike

- [ ] **Step 1: Uninstall the Helm release**

```bash
ssh root@192.168.1.52 "helm uninstall temporal-spike -n temporal-spike"
```
Expected: `release "temporal-spike" uninstalled`

- [ ] **Step 2: Delete the namespace (drops any leftover PVCs/configmaps)**

```bash
ssh root@192.168.1.52 "kubectl delete namespace temporal-spike --wait=true"
```
Expected: namespace deleted.

- [ ] **Step 3: Verify clean teardown**

```bash
ssh root@192.168.1.52 "kubectl get ns | grep temporal-spike"
```
Expected: no output (namespace gone). If a PVC is hung, investigate before continuing.

- [ ] **Step 4: Stop the port-forward backgrounded in Task 2 Step 1**

```bash
ssh root@192.168.1.52 "pkill -f 'kubectl.*port-forward.*temporal-spike'"
```

No commit needed for this task — teardown leaves nothing in the repo. Phase 0 complete.

---

## Phase 1 — Approval Gate End-to-End

### Task 4: Create repo scaffolding for outreach-schema and outreach-workflows

**Files:**
- Create: `apps/outreach-schema/README.md`
- Create: `apps/outreach-schema/dbmate.env.example`
- Create: `apps/outreach-schema/Makefile`
- Create: `apps/outreach-schema/db/migrations/.gitkeep`
- Create: `apps/outreach-schema/db/tests/.gitkeep`
- Create: `apps/outreach-workflows/README.md`
- Create: `apps/outreach-workflows/n8n/.gitkeep`
- Create: `apps/outreach-workflows/prompts/.gitkeep`

- [ ] **Step 1: Create the directories**

```bash
mkdir -p apps/outreach-schema/db/migrations apps/outreach-schema/db/tests
mkdir -p apps/outreach-workflows/n8n apps/outreach-workflows/prompts
touch apps/outreach-schema/db/migrations/.gitkeep apps/outreach-schema/db/tests/.gitkeep
touch apps/outreach-workflows/n8n/.gitkeep apps/outreach-workflows/prompts/.gitkeep
```

- [ ] **Step 2: Write `apps/outreach-schema/README.md`**

```markdown
# outreach-schema

Database schema and migrations for the PlotLens outreach pipeline. Single Postgres database `outreach` on LXC 114.

## Apply migrations

```bash
cp dbmate.env.example .env
# edit .env to set DATABASE_URL pointing at LXC 114 outreach DB
make migrate
```

## Roll back the last migration

```bash
make rollback
```

## Run trigger-enforcement tests

```bash
make test
```

See the spec at `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md` for the schema design and the safety rationale behind the `publish_jobs` enforcement trigger.
```

- [ ] **Step 3: Write `apps/outreach-schema/dbmate.env.example`**

```bash
# Copy to .env and fill in. Never commit .env.
DATABASE_URL=postgres://outreach_admin:CHANGEME@192.168.1.114:5432/outreach?sslmode=disable
DBMATE_MIGRATIONS_DIR=db/migrations
DBMATE_SCHEMA_FILE=db/schema.sql
```

- [ ] **Step 4: Write `apps/outreach-schema/Makefile`**

```make
.PHONY: migrate rollback status test clean

migrate:
	dbmate up

rollback:
	dbmate rollback

status:
	dbmate status

test:
	./db/tests/run_tests.sh

clean:
	rm -f db/schema.sql
```

- [ ] **Step 5: Write `apps/outreach-workflows/README.md`**

```markdown
# outreach-workflows

n8n workflow exports and supporting config for the PlotLens outreach pipeline.

## Layout

- `n8n/*.json` — exported workflow JSON. Edit in the n8n UI, then re-export with `n8n export:workflow --id=<id> --output=...`.
- `prompts/*.md` — versioned LLM prompts. `drafts.prompt_version` references these by filename.
- `credentials-matrix.yaml` — declarative allowlist of which credentials each workflow may reference.
- `rss-feeds.yaml` — seed list of RSS sources for Workflow A.

## Updating a workflow

1. Edit the workflow in n8n UI at https://n8n.corbello.io
2. Export: `pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/workflow.json`
3. Copy to repo: `scp root@192.168.1.80:/tmp/workflow.json apps/outreach-workflows/n8n/<name>.json`
4. Run the audit locally: `python -m scripts.n8n.audit_credentials apps/outreach-workflows/`
5. Commit and push. CI runs the audit again.
```

- [ ] **Step 6: Commit**

```bash
git add apps/outreach-schema apps/outreach-workflows
git commit -m "chore(outreach): scaffold outreach-schema and outreach-workflows directories"
```

### Task 5: Create `outreach` database and admin role on LXC 114

**Files:**
- No repo changes (operational task on LXC 114)

- [ ] **Step 1: SSH to LXC 114 and create the database**

```bash
ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -c \"CREATE DATABASE outreach;\""
```
Expected: `CREATE DATABASE`. If the DB already exists, the command fails — manually verify it's empty or pick a different name and update the spec.

- [ ] **Step 2: Create an admin role for dbmate migrations**

Generate a strong password first (locally):
```bash
openssl rand -base64 24
```
Then on LXC 114:
```bash
ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -c \"CREATE ROLE outreach_admin WITH LOGIN PASSWORD 'PASTE_PASSWORD_HERE';\""
ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE outreach TO outreach_admin;\""
ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -d outreach -c \"GRANT ALL ON SCHEMA public TO outreach_admin;\""
```
Expected: each `GRANT` returns `GRANT`.

- [ ] **Step 3: Store the admin password in Infisical**

Add a secret named `OUTREACH_DB_ADMIN_URL` to the Infisical `dev` environment with value `postgres://outreach_admin:<password>@192.168.1.114:5432/outreach?sslmode=disable`. (Do this in the Infisical UI at https://infisical.corbello.io — operational task.)

- [ ] **Step 4: Verify connectivity from your workstation**

```bash
psql 'postgres://outreach_admin:<password>@192.168.1.114:5432/outreach?sslmode=disable' -c 'SELECT version();'
```
Expected: Postgres version banner. If the connection is refused, check `pg_hba.conf` on LXC 114 — may need a `host outreach outreach_admin 192.168.1.0/24 md5` entry.

No commit. This is operational setup.

### Task 6: Install dbmate locally and confirm

**Files:**
- No repo changes

- [ ] **Step 1: Install dbmate**

```bash
brew install dbmate  # or `curl -fsSL -o /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64 && chmod +x /usr/local/bin/dbmate`
dbmate --version
```
Expected: prints a version (e.g. `1.x.x`).

- [ ] **Step 2: From the repo, copy env example and fill in the connection string from Infisical**

```bash
cd apps/outreach-schema
cp dbmate.env.example .env
# Edit .env, paste OUTREACH_DB_ADMIN_URL value
```
.env is gitignored by default repo settings; verify it doesn't appear in `git status`.

- [ ] **Step 3: Initialize dbmate (no migrations yet)**

```bash
dbmate status
```
Expected: empty status table, no pending or applied migrations.

### Task 7: Migration — `outreach_items` table

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260519120000_create_outreach_items.sql`

- [ ] **Step 1: Generate the migration file via dbmate**

```bash
cd apps/outreach-schema
dbmate new create_outreach_items
```
This creates a file like `db/migrations/<timestamp>_create_outreach_items.sql`. **Rename it** to use the canonical timestamp `20260519120000_create_outreach_items.sql` for consistency across reviewers.

- [ ] **Step 2: Write the migration body**

Replace the file contents with:
```sql
-- migrate:up
CREATE TABLE outreach_items (
  id              BIGSERIAL PRIMARY KEY,
  source_platform TEXT NOT NULL CHECK (source_platform IN ('manual','rss','reddit','x','bluesky','mastodon','google_alerts')),
  source_url      TEXT NOT NULL,
  source_excerpt  TEXT,
  source_author   TEXT,
  source_community TEXT,
  topic           TEXT,
  persona         TEXT,
  intent_score    SMALLINT CHECK (intent_score BETWEEN 0 AND 100),
  risk_score      SMALLINT CHECK (risk_score BETWEEN 0 AND 100),
  status          TEXT NOT NULL DEFAULT 'discovered'
                    CHECK (status IN ('discovered','drafting','drafted','reviewed','rejected','archived')),
  discovered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_platform, source_url)
);
CREATE INDEX idx_outreach_items_status_discovered_at ON outreach_items (status, discovered_at);

-- migrate:down
DROP TABLE outreach_items;
```

- [ ] **Step 3: Apply locally**

```bash
dbmate up
```
Expected: `Applying: 20260519120000_create_outreach_items.sql`. Verify:
```bash
psql "$DATABASE_URL" -c '\d outreach_items'
```
Should list the columns.

- [ ] **Step 4: Test rollback works**

```bash
dbmate rollback
psql "$DATABASE_URL" -c '\d outreach_items'  # expect error: relation does not exist
dbmate up
```

- [ ] **Step 5: Commit**

```bash
git add apps/outreach-schema/db/migrations/20260519120000_create_outreach_items.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add outreach_items table"
```

### Task 8: Migration — `drafts` table

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260519120100_create_drafts.sql`

- [ ] **Step 1: Create migration file**

```bash
cd apps/outreach-schema
dbmate new create_drafts
# rename to 20260519120100_create_drafts.sql
```

- [ ] **Step 2: Write the migration**

```sql
-- migrate:up
CREATE TABLE drafts (
  id                BIGSERIAL PRIMARY KEY,
  outreach_item_id  BIGINT NOT NULL REFERENCES outreach_items(id),
  variant           TEXT NOT NULL CHECK (variant IN ('helpful_only','founder_context','soft_product')),
  model_provider    TEXT NOT NULL,
  model_name        TEXT NOT NULL,
  prompt_version    TEXT NOT NULL,
  draft_text        TEXT NOT NULL,
  suggested_destination TEXT NOT NULL,
  suggested_post_type   TEXT NOT NULL,
  claims_to_verify  JSONB NOT NULL DEFAULT '[]'::jsonb,
  risk_flags        JSONB NOT NULL DEFAULT '[]'::jsonb,
  risk_score        SMALLINT NOT NULL DEFAULT 50 CHECK (risk_score BETWEEN 0 AND 100),
  manual_only       BOOLEAN NOT NULL DEFAULT false,
  content_hash      TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'needs_human_review'
                      CHECK (status IN ('needs_human_review','approved','rejected','expired')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_drafts_status_created_at ON drafts (status, created_at);

-- migrate:down
DROP TABLE drafts;
```

- [ ] **Step 3: Apply and verify**

```bash
dbmate up
psql "$DATABASE_URL" -c '\d drafts'
```

- [ ] **Step 4: Commit**

```bash
git add apps/outreach-schema/db/migrations/20260519120100_create_drafts.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add drafts table with risk_score"
```

### Task 9: Migration — `approvals` table

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260519120200_create_approvals.sql`

- [ ] **Step 1: Generate file (rename to canonical timestamp)**

```bash
cd apps/outreach-schema && dbmate new create_approvals
# rename to 20260519120200_create_approvals.sql
```

- [ ] **Step 2: Write migration**

```sql
-- migrate:up
CREATE TABLE approvals (
  id                       BIGSERIAL PRIMARY KEY,
  draft_id                 BIGINT NOT NULL REFERENCES drafts(id),
  approved_by              TEXT NOT NULL,
  decision                 TEXT NOT NULL CHECK (decision IN ('approved','rejected','manual_only','save_for_later')),
  edited_text              TEXT,
  approved_destination     TEXT NOT NULL,
  approved_post_type       TEXT NOT NULL,
  approved_content_hash    TEXT NOT NULL,
  approval_notes           TEXT,
  approved_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at               TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '7 days')
);

-- migrate:down
DROP TABLE approvals;
```

- [ ] **Step 3: Apply, verify, commit**

```bash
dbmate up
psql "$DATABASE_URL" -c '\d approvals'
git add apps/outreach-schema/db/migrations/20260519120200_create_approvals.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add approvals table"
```

### Task 10: Migration — `publish_jobs` table

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260519120300_create_publish_jobs.sql`

- [ ] **Step 1: Generate + rename**

```bash
cd apps/outreach-schema && dbmate new create_publish_jobs
# rename to 20260519120300_create_publish_jobs.sql
```

- [ ] **Step 2: Write migration**

```sql
-- migrate:up
CREATE TABLE publish_jobs (
  id                     BIGSERIAL PRIMARY KEY,
  approval_id            BIGINT NOT NULL REFERENCES approvals(id),
  destination_platform   TEXT NOT NULL,
  destination_account    TEXT NOT NULL,
  postiz_integration_id  TEXT,
  scheduled_for          TIMESTAMPTZ,
  publish_mode           TEXT NOT NULL CHECK (publish_mode IN ('postiz_scheduled','postiz_immediate','manual_required')),
  status                 TEXT NOT NULL DEFAULT 'ready'
                          CHECK (status IN ('ready','sent_to_postiz','scheduled','published','manual_post_required','failed','expired')),
  postiz_post_id         TEXT,
  published_url          TEXT,
  published_at           TIMESTAMPTZ,
  failure_reason         TEXT,
  payload_hash           TEXT NOT NULL
);
CREATE INDEX idx_publish_jobs_status_scheduled ON publish_jobs (status, scheduled_for);

-- migrate:down
DROP TABLE publish_jobs;
```

- [ ] **Step 3: Apply, verify, commit**

```bash
dbmate up
psql "$DATABASE_URL" -c '\d publish_jobs'
git add apps/outreach-schema/db/migrations/20260519120300_create_publish_jobs.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add publish_jobs table (trigger added in next migration)"
```

### Task 11: Migration — `outcomes` table

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260519120400_create_outcomes.sql`

- [ ] **Step 1: Generate + rename**

```bash
cd apps/outreach-schema && dbmate new create_outcomes
# rename to 20260519120400_create_outcomes.sql
```

- [ ] **Step 2: Write migration**

```sql
-- migrate:up
CREATE TABLE outcomes (
  id              BIGSERIAL PRIMARY KEY,
  publish_job_id  BIGINT NOT NULL REFERENCES publish_jobs(id),
  impressions     INT,
  replies         INT,
  clicks          INT,
  signups         INT,
  notes           TEXT,
  captured_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- migrate:down
DROP TABLE outcomes;
```

- [ ] **Step 3: Apply, verify, commit**

```bash
dbmate up
psql "$DATABASE_URL" -c '\d outcomes'
git add apps/outreach-schema/db/migrations/20260519120400_create_outcomes.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add outcomes table"
```

### Task 12: TDD — write trigger enforcement tests (failing)

**Files:**
- Create: `apps/outreach-schema/db/tests/trigger_enforcement_test.sql`
- Create: `apps/outreach-schema/db/tests/run_tests.sh`

This task writes the failing tests for the publish_jobs enforcement trigger. The trigger itself doesn't exist yet — these tests will FAIL until Task 13 creates it. That's the point.

- [ ] **Step 1: Write the test runner script**

Create `apps/outreach-schema/db/tests/run_tests.sh`:
```bash
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL must be set" >&2
  exit 2
fi

cd "$(dirname "$0")"

# Wrap each test in a transaction that is rolled back at the end, so tests don't pollute state.
# psql exits non-zero on EXCEPTION inside the transaction; that's what we use to assert.

run_expect_fail() {
  local label="$1"
  local sql="$2"
  if echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
    echo "FAIL: $label — expected EXCEPTION, got success"
    return 1
  else
    echo "PASS: $label"
    return 0
  fi
}

run_expect_pass() {
  local label="$1"
  local sql="$2"
  if echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
    echo "PASS: $label"
    return 0
  else
    echo "FAIL: $label — expected success, got error"
    echo "  Re-running to capture error:"
    echo "BEGIN; $sql ROLLBACK;" | psql "$DATABASE_URL" -v ON_ERROR_STOP=1 || true
    return 1
  fi
}

source ./trigger_enforcement_test.sql.sh
```

Make it executable:
```bash
chmod +x apps/outreach-schema/db/tests/run_tests.sh
```

- [ ] **Step 2: Write the test fixtures as a sourceable script**

Create `apps/outreach-schema/db/tests/trigger_enforcement_test.sql.sh`:
```bash
# Sourced by run_tests.sh. Each test inserts seed data, attempts the publish_job insert, expects the trigger outcome.

# Common seed used by every test
SEED="
  INSERT INTO outreach_items (source_platform, source_url) VALUES ('manual', 'https://example.com/seed') RETURNING id \\gset oi_
  INSERT INTO drafts (outreach_item_id, variant, model_provider, model_name, prompt_version, draft_text, suggested_destination, suggested_post_type, content_hash)
    VALUES (:oi_id, 'helpful_only', 'anthropic', 'claude-sonnet-4-6', 'draft-v1', 'hello world', 'x_post', 'thread', 'abc123') RETURNING id \\gset d_
"

# Test 1: rejected decision must block publish_jobs insert
run_expect_fail "rejects publish_job for rejected approval" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash)
    VALUES (:d_id, 'jeremy', 'rejected', 'x_post', 'thread', 'abc123') RETURNING id \\gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'abc123');
"

# Test 2: expired approval must block publish_jobs insert
run_expect_fail "rejects publish_job for expired approval" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash, expires_at)
    VALUES (:d_id, 'jeremy', 'approved', 'x_post', 'thread', 'abc123', now() - INTERVAL '1 hour') RETURNING id \\gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'abc123');
"

# Test 3: mismatched payload_hash must block publish_jobs insert
run_expect_fail "rejects publish_job with mismatched payload_hash" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash)
    VALUES (:d_id, 'jeremy', 'approved', 'x_post', 'thread', 'abc123') RETURNING id \\gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'WRONG_HASH');
"

# Test 4: happy path — approved + unexpired + matching hash → INSERT succeeds
run_expect_pass "accepts publish_job for valid approval" "
  $SEED
  INSERT INTO approvals (draft_id, approved_by, decision, approved_destination, approved_post_type, approved_content_hash)
    VALUES (:d_id, 'jeremy', 'approved', 'x_post', 'thread', 'abc123') RETURNING id \\gset a_
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
    VALUES (:a_id, 'x', 'plotlens', 'postiz_immediate', 'abc123');
"
```

Make it executable:
```bash
chmod +x apps/outreach-schema/db/tests/trigger_enforcement_test.sql.sh
```

- [ ] **Step 3: Run the tests — they should all FAIL (no trigger yet)**

```bash
cd apps/outreach-schema
source .env
./db/tests/run_tests.sh || true  # don't exit shell on test failure
```

Expected output:
```
FAIL: rejects publish_job for rejected approval — expected EXCEPTION, got success
FAIL: rejects publish_job for expired approval — expected EXCEPTION, got success
FAIL: rejects publish_job with mismatched payload_hash — expected EXCEPTION, got success
PASS: accepts publish_job for valid approval
```

Three of four failing is expected — that's the "red" state of TDD. Test 4 passes because without the trigger, all inserts succeed.

- [ ] **Step 4: Commit the failing tests**

```bash
git add apps/outreach-schema/db/tests
git commit -m "test(outreach-schema): add trigger enforcement tests (currently failing)"
```

### Task 13: Migration — create `enforce_approval_match` trigger (tests pass)

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260519120500_create_enforce_approval_trigger.sql`

- [ ] **Step 1: Generate + rename**

```bash
cd apps/outreach-schema && dbmate new create_enforce_approval_trigger
# rename to 20260519120500_create_enforce_approval_trigger.sql
```

- [ ] **Step 2: Write the trigger migration**

```sql
-- migrate:up
CREATE OR REPLACE FUNCTION enforce_approval_match() RETURNS trigger AS $$
DECLARE a approvals%ROWTYPE;
BEGIN
  SELECT * INTO a FROM approvals WHERE id = NEW.approval_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'publish_job approval_id=% not found', NEW.approval_id;
  END IF;
  IF a.decision <> 'approved' THEN
    RAISE EXCEPTION 'publish_job approval_id=% has decision=%, must be approved', NEW.approval_id, a.decision;
  END IF;
  IF a.expires_at < now() THEN
    RAISE EXCEPTION 'publish_job approval_id=% expired at %', NEW.approval_id, a.expires_at;
  END IF;
  IF NEW.payload_hash <> a.approved_content_hash THEN
    RAISE EXCEPTION 'publish_job payload_hash does not match approved_content_hash';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_enforce_approval_match
  BEFORE INSERT OR UPDATE OF payload_hash, approval_id ON publish_jobs
  FOR EACH ROW EXECUTE FUNCTION enforce_approval_match();

-- migrate:down
DROP TRIGGER IF EXISTS trg_enforce_approval_match ON publish_jobs;
DROP FUNCTION IF EXISTS enforce_approval_match();
```

- [ ] **Step 3: Apply the migration**

```bash
dbmate up
```

- [ ] **Step 4: Re-run tests — all should now PASS**

```bash
./db/tests/run_tests.sh
```

Expected output:
```
PASS: rejects publish_job for rejected approval
PASS: rejects publish_job for expired approval
PASS: rejects publish_job with mismatched payload_hash
PASS: accepts publish_job for valid approval
```

If any test still fails, debug the trigger before continuing — this is the load-bearing safety mechanism.

- [ ] **Step 5: Commit**

```bash
git add apps/outreach-schema/db/migrations/20260519120500_create_enforce_approval_trigger.sql apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add enforce_approval_match trigger on publish_jobs"
```

### Task 14: Create n8n DB role with constrained privileges

**Files:**
- No repo changes (operational)

- [ ] **Step 1: Generate a password and create the role**

```bash
N8N_PW=$(openssl rand -base64 24)
echo "store this: $N8N_PW"
ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -d outreach -c \"CREATE ROLE outreach_n8n WITH LOGIN PASSWORD '$N8N_PW';\""
```

- [ ] **Step 2: Grant exactly the privileges n8n workflows need**

```bash
ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -d outreach <<SQL
GRANT CONNECT ON DATABASE outreach TO outreach_n8n;
GRANT USAGE ON SCHEMA public TO outreach_n8n;
GRANT SELECT, INSERT, UPDATE ON outreach_items, drafts, approvals, publish_jobs, outcomes TO outreach_n8n;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO outreach_n8n;
-- No DROP, no DELETE, no DDL.
SQL"
```

- [ ] **Step 3: Verify the role cannot DROP**

```bash
psql "postgres://outreach_n8n:$N8N_PW@192.168.1.114:5432/outreach?sslmode=disable" \
  -c 'DROP TABLE outcomes;'  # expect: ERROR: must be owner of table outcomes
```

- [ ] **Step 4: Store the connection string in Infisical**

Add `OUTREACH_DB_N8N_URL` to Infisical `dev` with `postgres://outreach_n8n:<password>@192.168.1.114:5432/outreach?sslmode=disable`.

### Task 15: Write credentials matrix YAML

**Files:**
- Create: `apps/outreach-workflows/credentials-matrix.yaml`

- [ ] **Step 1: Write the matrix**

```yaml
# Each workflow exported under n8n/ may reference credentials by ID.
# The audit script asserts no workflow references a credential whose name is not in its allow list.
# A workflow whose filename is not listed here is rejected by the audit (fail-closed).

workflows:
  discover:
    file: n8n/discover.json
    allow:
      - outreach-db-n8n         # SELECT/INSERT/UPDATE on outreach tables
      - discover-webhook-secret # HMAC secret for the manual paste webhook
      - rss-feed-list           # plain config, not really a credential but exposed as one for consistency

  draft:
    file: n8n/draft.json
    allow:
      - outreach-db-n8n
      - anthropic-api-key       # Claude Sonnet 4.6 + Haiku 4.5
      # NO Postiz. NO SES. NO Slack publishing.

  review:
    file: n8n/review.json
    allow:
      - outreach-db-n8n
      - slack-bot-token         # post + read interactions ONLY
      - n8n-form-auth           # optional Basic auth on the form URL

  manual-publish:
    file: n8n/manual-publish.json
    allow:
      - outreach-db-n8n
      - slack-bot-token         # send the DM to me with approved text

  expire-stale:
    file: n8n/expire-stale.json
    allow:
      - outreach-db-n8n

  smoke:
    file: n8n/smoke.json
    allow:
      - outreach-db-n8n
      - discover-webhook-secret  # pings its own webhook
      - slack-bot-token          # alerts if smoke fails

# Credentials that MUST NEVER appear in any of the above workflows.
# (Used in Phase 2+ workflows: publish-dispatcher, outcome-logger.)
forbidden_phase1:
  - postiz-api-key
  - ses-smtp-credentials
```

- [ ] **Step 2: Commit**

```bash
git add apps/outreach-workflows/credentials-matrix.yaml
git commit -m "feat(outreach-workflows): declare Phase 1 credentials allowlist"
```

### Task 16: TDD — audit-credentials.py tests (failing)

**Files:**
- Create: `tests/n8n/__init__.py` (empty)
- Create: `tests/n8n/conftest.py`
- Create: `tests/n8n/test_audit_credentials.py`
- Create: `tests/n8n/fixtures/workflow_compliant.json`
- Create: `tests/n8n/fixtures/workflow_violation.json`

- [ ] **Step 1: Create test fixtures — a compliant and a non-compliant workflow JSON**

Create `tests/n8n/fixtures/workflow_compliant.json`:
```json
{
  "name": "discover",
  "nodes": [
    {
      "id": "webhook-1",
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "parameters": {"path": "outreach-discover"},
      "credentials": {
        "httpHeaderAuth": {"id": "1", "name": "discover-webhook-secret"}
      }
    },
    {
      "id": "pg-1",
      "name": "Postgres",
      "type": "n8n-nodes-base.postgres",
      "credentials": {
        "postgres": {"id": "2", "name": "outreach-db-n8n"}
      }
    }
  ]
}
```

Create `tests/n8n/fixtures/workflow_violation.json`:
```json
{
  "name": "discover",
  "nodes": [
    {
      "id": "claude-1",
      "name": "Anthropic",
      "type": "@n8n/n8n-nodes-langchain.lmChatAnthropic",
      "credentials": {
        "anthropicApi": {"id": "5", "name": "anthropic-api-key"}
      }
    }
  ]
}
```

(The violation: the `discover` workflow's allowlist does not include `anthropic-api-key`.)

- [ ] **Step 2: Write the pytest fixtures + tests**

Create `tests/n8n/conftest.py`:
```python
from pathlib import Path
import pytest

FIXTURES_DIR = Path(__file__).parent / "fixtures"

@pytest.fixture
def matrix_yaml(tmp_path):
    """Minimal credentials matrix for tests."""
    matrix = tmp_path / "credentials-matrix.yaml"
    matrix.write_text(
        "workflows:\n"
        "  discover:\n"
        "    file: discover.json\n"
        "    allow:\n"
        "      - outreach-db-n8n\n"
        "      - discover-webhook-secret\n"
        "forbidden_phase1:\n"
        "  - postiz-api-key\n"
    )
    return matrix

@pytest.fixture
def compliant_workflow(tmp_path):
    src = FIXTURES_DIR / "workflow_compliant.json"
    dst = tmp_path / "discover.json"
    dst.write_text(src.read_text())
    return dst

@pytest.fixture
def violating_workflow(tmp_path):
    src = FIXTURES_DIR / "workflow_violation.json"
    dst = tmp_path / "discover.json"
    dst.write_text(src.read_text())
    return dst
```

Create `tests/n8n/test_audit_credentials.py`:
```python
import pytest
from scripts.n8n.audit_credentials import audit_workflow_dir, AuditViolation

def test_compliant_workflow_passes(tmp_path, matrix_yaml, compliant_workflow):
    # compliant_workflow lives in tmp_path; matrix_yaml lives in tmp_path
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert violations == []

def test_violating_workflow_fails(tmp_path, matrix_yaml, violating_workflow):
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert len(violations) == 1
    v = violations[0]
    assert v.workflow == "discover"
    assert v.disallowed_credential == "anthropic-api-key"

def test_unknown_workflow_file_is_violation(tmp_path, matrix_yaml):
    # A workflow JSON file with no matching entry in the matrix is fail-closed.
    rogue = tmp_path / "rogue.json"
    rogue.write_text('{"name": "rogue", "nodes": []}')
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert any(v.reason == "workflow_not_in_matrix" for v in violations)

def test_missing_workflow_file_is_violation(tmp_path, matrix_yaml):
    # The matrix lists discover.json but the file is missing.
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert any(v.reason == "workflow_file_missing" for v in violations)
```

Create empty `tests/n8n/__init__.py`.

- [ ] **Step 3: Run the tests — all should fail (module doesn't exist)**

```bash
cd /home/jacorbello/repos/cortech-infra
python -m pytest tests/n8n/ -v --no-cov
```

Expected: `ModuleNotFoundError: No module named 'scripts.n8n.audit_credentials'` for every test.

- [ ] **Step 4: Commit the failing tests**

```bash
git add tests/n8n/
git commit -m "test(n8n-audit): add failing tests for credentials audit script"
```

### Task 17: Implement audit-credentials.py (tests pass)

**Files:**
- Create: `scripts/n8n/__init__.py` (empty)
- Create: `scripts/n8n/audit_credentials.py`

- [ ] **Step 1: Add pyyaml to test deps**

Edit `requirements-test.txt`:
```
pytest
pytest-cov
responses
pyyaml
```

- [ ] **Step 2: Write the audit script**

Create empty `scripts/n8n/__init__.py`.

Create `scripts/n8n/audit_credentials.py`:
```python
"""Audit n8n workflow JSON exports against a declarative credentials allowlist.

Usage:
    python -m scripts.n8n.audit_credentials apps/outreach-workflows/

Exit code 0: no violations. Exit code 1: violations printed to stderr.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass
class AuditViolation:
    workflow: str
    reason: str
    disallowed_credential: str | None = None
    file_path: str | None = None

    def format(self) -> str:
        if self.reason == "disallowed_credential":
            return (
                f"{self.workflow}: references credential "
                f"'{self.disallowed_credential}' which is not in its allowlist"
            )
        if self.reason == "forbidden_phase1_credential":
            return (
                f"{self.workflow}: references forbidden Phase 1 credential "
                f"'{self.disallowed_credential}'"
            )
        if self.reason == "workflow_not_in_matrix":
            return (
                f"{self.workflow}: file present but no entry in credentials-matrix.yaml "
                f"(fail-closed)"
            )
        if self.reason == "workflow_file_missing":
            return f"{self.workflow}: matrix entry exists but file missing at {self.file_path}"
        return f"{self.workflow}: {self.reason}"


def _extract_credentials(workflow_json: dict) -> list[str]:
    """Return the list of credential names referenced anywhere in the workflow."""
    names: list[str] = []
    for node in workflow_json.get("nodes", []):
        creds = node.get("credentials") or {}
        for cred_def in creds.values():
            name = cred_def.get("name")
            if name:
                names.append(name)
    return names


def audit_workflow_dir(workflow_dir: Path, matrix_path: Path) -> list[AuditViolation]:
    """Audit every workflow JSON in `workflow_dir` against `matrix_path`."""
    matrix = yaml.safe_load(matrix_path.read_text())
    workflows_spec = matrix.get("workflows", {})
    forbidden_phase1 = set(matrix.get("forbidden_phase1", []))

    violations: list[AuditViolation] = []

    # Build a map of expected filenames to their spec
    expected_files = {
        Path(spec["file"]).name: (name, spec)
        for name, spec in workflows_spec.items()
    }

    # Check each JSON file in the workflow_dir
    found_files: set[str] = set()
    for json_file in workflow_dir.glob("*.json"):
        found_files.add(json_file.name)
        if json_file.name not in expected_files:
            violations.append(
                AuditViolation(
                    workflow=json_file.stem,
                    reason="workflow_not_in_matrix",
                    file_path=str(json_file),
                )
            )
            continue

        workflow_name, spec = expected_files[json_file.name]
        allowed = set(spec.get("allow", []))
        wf_json = json.loads(json_file.read_text())
        for cred_name in _extract_credentials(wf_json):
            if cred_name in forbidden_phase1:
                violations.append(
                    AuditViolation(
                        workflow=workflow_name,
                        reason="forbidden_phase1_credential",
                        disallowed_credential=cred_name,
                    )
                )
            elif cred_name not in allowed:
                violations.append(
                    AuditViolation(
                        workflow=workflow_name,
                        reason="disallowed_credential",
                        disallowed_credential=cred_name,
                    )
                )

    # Check for missing files
    for expected_name, (workflow_name, spec) in expected_files.items():
        if expected_name not in found_files:
            violations.append(
                AuditViolation(
                    workflow=workflow_name,
                    reason="workflow_file_missing",
                    file_path=spec["file"],
                )
            )

    return violations


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("Usage: audit_credentials.py <workflow-dir>", file=sys.stderr)
        return 2
    workflow_dir = Path(argv[1])
    matrix_path = workflow_dir / "credentials-matrix.yaml"
    if not matrix_path.exists():
        # If we were passed the parent, look one level in
        alt = workflow_dir / "outreach-workflows" / "credentials-matrix.yaml"
        if alt.exists():
            matrix_path = alt
            workflow_dir = workflow_dir / "outreach-workflows" / "n8n"
        else:
            print(f"ERROR: credentials-matrix.yaml not found near {workflow_dir}", file=sys.stderr)
            return 2
    else:
        workflow_dir = workflow_dir / "n8n"

    violations = audit_workflow_dir(workflow_dir=workflow_dir, matrix_path=matrix_path)
    if violations:
        print(f"{len(violations)} violation(s):", file=sys.stderr)
        for v in violations:
            print(f"  - {v.format()}", file=sys.stderr)
        return 1
    print("Audit passed: no credential violations.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 3: Run the tests — should now pass**

```bash
pip install -r requirements-test.txt
python -m pytest tests/n8n/ -v --no-cov
```

Expected: 4 passed.

- [ ] **Step 4: Run the script against the (empty for now) outreach-workflows directory**

```bash
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```

Expected: 6 violations of `workflow_file_missing` (one per matrix entry) — this is correct; the workflows haven't been exported yet. We'll see them clear as each workflow is built.

- [ ] **Step 5: Commit**

```bash
git add scripts/n8n/ requirements-test.txt
git commit -m "feat(n8n-audit): implement credentials audit script"
```

### Task 18: Add CI workflow

**Files:**
- Create: `.github/workflows/outreach-ci.yml`

- [ ] **Step 1: Write the CI workflow**

```yaml
name: Outreach CI

on:
  pull_request:
    paths:
      - "apps/outreach-schema/**"
      - "apps/outreach-workflows/**"
      - "scripts/n8n/**"
      - "tests/n8n/**"
      - ".github/workflows/outreach-ci.yml"
  push:
    branches: [main]
    paths:
      - "apps/outreach-schema/**"
      - "apps/outreach-workflows/**"
      - "scripts/n8n/**"
      - "tests/n8n/**"

permissions:
  contents: read

jobs:
  schema:
    runs-on: cortech-infra-runner
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: ci
          POSTGRES_DB: outreach
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
    env:
      DATABASE_URL: postgres://postgres:ci@localhost:5432/outreach?sslmode=disable
    steps:
      - uses: actions/checkout@v4
      - name: Install dbmate
        run: |
          sudo curl -fsSL -o /usr/local/bin/dbmate \
            https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64
          sudo chmod +x /usr/local/bin/dbmate
      - name: Apply migrations
        working-directory: apps/outreach-schema
        run: dbmate up
      - name: Rollback migrations (verify down paths work)
        working-directory: apps/outreach-schema
        run: |
          for _ in $(seq 1 6); do dbmate rollback; done
          dbmate up
      - name: Run trigger enforcement tests
        working-directory: apps/outreach-schema
        run: ./db/tests/run_tests.sh

  audit:
    runs-on: cortech-infra-runner
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install deps
        run: pip install -r requirements-test.txt
      - name: Run audit tests
        run: python -m pytest tests/n8n/ -v --no-cov
      - name: Run audit against repo workflows
        run: python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```

- [ ] **Step 2: Commit and verify CI runs on PR**

```bash
git add .github/workflows/outreach-ci.yml
git commit -m "ci(outreach): add migration + audit pipeline"
```

Open a draft PR and confirm both `schema` and `audit` jobs run. The audit job will fail on workflow_file_missing — that's expected until workflows are built. Comment that on the PR.

### Task 19: Slack workspace setup

**Files:**
- No repo changes (operational)

- [ ] **Step 1: Create `#plotlens-outreach` channel** in the PlotLens Slack workspace.

- [ ] **Step 2: Create a Slack app at api.slack.com/apps named "PlotLens Outreach"**

Scopes needed (Bot Token Scopes):
- `chat:write` (post messages)
- `chat:write.public` (post to channels without joining)
- `channels:read` (resolve channel ID)
- `im:write` (send DMs)
- `commands` (if you want slash commands later — not required for v1)
- Required for interactive buttons: enable Interactivity & Shortcuts, set Request URL to `https://n8n.corbello.io/webhook/slack-interactive` (you'll wire this in T26).

Install the app to the PlotLens workspace, copy the Bot User OAuth Token (`xoxb-…`).

- [ ] **Step 3: Capture the Signing Secret** from Basic Information → App Credentials. Both go into Infisical.

- [ ] **Step 4: Store credentials in Infisical `dev` env**

Add:
- `SLACK_BOT_TOKEN` = `xoxb-…`
- `SLACK_SIGNING_SECRET` = `…`
- `SLACK_OUTREACH_CHANNEL_ID` = channel ID from Slack (right-click channel → Copy link, ID is the last path segment)

- [ ] **Step 5: Verify the bot can post**

From your workstation:
```bash
curl -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"channel":"'"$SLACK_OUTREACH_CHANNEL_ID"'","text":"PlotLens outreach bot test"}'
```
Expected: response `{"ok":true,...}` and the message appears in the channel.

### Task 20: Configure n8n credentials per the matrix

**Files:**
- No repo changes (operational n8n config)

- [ ] **Step 1: SSH to n8n LXC and list existing credentials** to make sure new ones don't collide:

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n list:credentials"
```

- [ ] **Step 2: In n8n UI (https://n8n.corbello.io), create exactly these credentials** with names matching the matrix:

| Credential name | Type | Value source |
|---|---|---|
| `outreach-db-n8n` | Postgres | Infisical `OUTREACH_DB_N8N_URL` |
| `discover-webhook-secret` | Header Auth (`X-Discover-Secret`) | Generate with `openssl rand -hex 32`; store in Infisical `DISCOVER_WEBHOOK_SECRET` |
| `rss-feed-list` | Generic Credential Type with a single JSON field | Reference content (overwritten in T22 with the seed list) |
| `anthropic-api-key` | Anthropic API | Infisical `ANTHROPIC_API_KEY` |
| `slack-bot-token` | Slack OAuth2 (or Bot Token) | Infisical `SLACK_BOT_TOKEN` |
| `n8n-form-auth` | Basic Auth | Generated locally, stored in Infisical `N8N_FORM_AUTH_USER` + `_PASSWORD` |

- [ ] **Step 3: Confirm each credential's "Test" passes** in the n8n UI before using it.

### Task 21: Workflow A — Discover (manual webhook only)

**Files:**
- Create: `apps/outreach-workflows/n8n/discover.json`

This task builds the workflow in the n8n UI, exports it, and commits the JSON.

- [ ] **Step 1: In n8n UI, create a new workflow named `outreach-discover`** with these nodes:

1. **Webhook** node:
   - HTTP Method: POST
   - Path: `outreach-discover`
   - Authentication: Header Auth → credential `discover-webhook-secret`
   - Response Mode: Last Node
   - Output: `{ url, notes }` from `$json.body`

2. **Function** node — normalize input:
   ```javascript
   const url = $json.body.url;
   if (!url || !url.match(/^https?:\/\//)) {
     throw new Error("invalid url");
   }
   return [{
     json: {
       source_platform: "manual",
       source_url: url,
       source_excerpt: $json.body.notes || null,
     }
   }];
   ```

3. **Postgres** node — credential `outreach-db-n8n`, operation Execute Query:
   ```sql
   INSERT INTO outreach_items (source_platform, source_url, source_excerpt)
   VALUES ($1, $2, $3)
   ON CONFLICT (source_platform, source_url) DO NOTHING
   RETURNING id;
   ```
   Parameters: `={{$json.source_platform}}`, `={{$json.source_url}}`, `={{$json.source_excerpt}}`

4. **Respond to Webhook** node — body `={{ {accepted: true, id: $json.id} }}`

- [ ] **Step 2: Activate the workflow and smoke-test it**

```bash
SECRET=$(infisical secrets get --env=dev DISCOVER_WEBHOOK_SECRET --raw)
curl -X POST https://n8n.corbello.io/webhook/outreach-discover \
  -H "X-Discover-Secret: $SECRET" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/test-post","notes":"smoke test"}'
```
Expected response: `{"accepted": true, "id": 1}` (or whatever the new row id is).

Verify in DB:
```bash
psql "$OUTREACH_DB_ADMIN_URL" -c "SELECT id, source_url, status FROM outreach_items WHERE source_url='https://example.com/test-post';"
```

- [ ] **Step 3: Export the workflow**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<workflow-id> --output=/tmp/discover.json"
scp root@192.168.1.80:/tmp/discover.json apps/outreach-workflows/n8n/discover.json
```

- [ ] **Step 4: Run audit locally — it should now pass for `discover.json`**

```bash
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```
Expected: 5 remaining `workflow_file_missing` violations (draft, review, manual-publish, expire-stale, smoke). `discover` is clean.

- [ ] **Step 5: Commit**

```bash
git add apps/outreach-workflows/n8n/discover.json
git commit -m "feat(outreach-workflows): add Discover workflow with manual webhook trigger"
```

### Task 22: Workflow A — add RSS triggers + seed feed list

**Files:**
- Create: `apps/outreach-workflows/rss-feeds.yaml`
- Modify: `apps/outreach-workflows/n8n/discover.json` (re-export after adding RSS branch)

- [ ] **Step 1: Pick 5 writing-craft RSS feeds**

Recommended starting set (verify each is alive in your browser first):
- https://thecreativepenn.com/feed/
- https://writershelpingwriters.net/feed/
- https://janefriedman.com/feed/
- https://www.helpingwritersbecomeauthors.com/feed/
- https://blog.reedsy.com/feed/

(If any is dead at execution time, swap with a comparable writing-craft blog.)

Create `apps/outreach-workflows/rss-feeds.yaml`:
```yaml
# Seed RSS feeds for Workflow A's scheduled discovery.
# Mirrored into the n8n "rss-feed-list" credential JSON; this YAML is the source of truth for review.
feeds:
  - name: The Creative Penn
    url: https://thecreativepenn.com/feed/
  - name: Writers Helping Writers
    url: https://writershelpingwriters.net/feed/
  - name: Jane Friedman
    url: https://janefriedman.com/feed/
  - name: Helping Writers Become Authors
    url: https://www.helpingwritersbecomeauthors.com/feed/
  - name: Reedsy
    url: https://blog.reedsy.com/feed/
```

- [ ] **Step 2: Add a Schedule Trigger + RSS Read branch to the existing `outreach-discover` workflow**

In n8n UI, add to the existing workflow:

1. **Schedule Trigger** node — every 30 minutes
2. **Split In Batches** node fed by an array of `{name, url}` (paste from `rss-feeds.yaml`, or read from the `rss-feed-list` credential)
3. **RSS Read** node — `url` = `={{$json.url}}`
4. **Function** node — normalize each item:
   ```javascript
   return items.map(item => ({
     json: {
       source_platform: "rss",
       source_url: item.json.link,
       source_excerpt: (item.json.contentSnippet || "").slice(0, 1000),
       source_author: item.json.creator || null,
     }
   }));
   ```
5. **Postgres** node — reuse the same INSERT … ON CONFLICT statement from T21 Step 1 with the appropriate parameter bindings.

(The manual-webhook path and RSS path can share the Postgres insert node by merging branches.)

- [ ] **Step 3: Smoke-test the RSS branch**

Manually trigger the Schedule node once in n8n UI. Verify rows appear in `outreach_items` with `source_platform='rss'`.

- [ ] **Step 4: Re-export and audit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/discover.json"
scp root@192.168.1.80:/tmp/discover.json apps/outreach-workflows/n8n/discover.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```
Expected: still no violation for discover.

- [ ] **Step 5: Commit**

```bash
git add apps/outreach-workflows/rss-feeds.yaml apps/outreach-workflows/n8n/discover.json
git commit -m "feat(outreach-workflows): add RSS triggers to Discover workflow with 5 seed feeds"
```

### Task 23: Commit prompt v1

**Files:**
- Create: `apps/outreach-workflows/prompts/draft-v1.md`
- Create: `apps/outreach-workflows/prompts/risk-check-v1.md`

- [ ] **Step 1: Write the draft prompt**

Create `apps/outreach-workflows/prompts/draft-v1.md`:

```markdown
# Draft Prompt v1

You are drafting outreach as the founder of PlotLens. PlotLens is narrative intelligence for fiction writers: it extracts story canon (characters, locations, timelines, rules) and validates continuity across a manuscript. **It does not generate prose.**

## Source context

- Platform: {{source_platform}}
- URL: {{source_url}}
- Author / community: {{source_author}} / {{source_community}}
- Excerpt:
  > {{source_excerpt}}

## Voice rules

- Calm, practical, writer-friendly. No hype. No "AI slop."
- Avoid developer jargon: entities, validation rules, embeddings, canonical graph.
- Prefer writer language: characters, story bible, continuity, source passage, manuscript.
- Never claim PlotLens writes prose.
- Never invent features, launch dates, metrics, integrations, prices, or customer counts.

## Channel rules

- For Reddit: no sales CTA unless the post directly asks for tools.
- For replies: answer the person's actual problem before mentioning anything we built.
- For X/Bluesky/Mastodon original posts: stand-alone, useful even if no one clicks through.

## Output

Return JSON with exactly these fields:

```json
{
  "should_reply": true | false,
  "recommended_destination": "reddit_reply" | "reddit_post" | "x_post" | "x_reply" | "bluesky_post" | "mastodon_post" | "linkedin_post" | "newsletter",
  "manual_only": true | false,
  "drafts": [
    {
      "variant": "helpful_only",
      "draft_text": "...",
      "risk_flags": ["e.g. mentions_pricing", "..."]
    },
    {
      "variant": "founder_context",
      "draft_text": "...",
      "risk_flags": []
    },
    {
      "variant": "soft_product",
      "draft_text": "...",
      "risk_flags": []
    }
  ]
}
```

- One variant per `variant` key. Always return all three.
- `risk_flags` is a list of short strings naming any concern (mentions pricing, makes a claim about features, refers to a competitor, etc.). Empty list if clean.
```

- [ ] **Step 2: Write the risk-check prompt**

Create `apps/outreach-workflows/prompts/risk-check-v1.md`:

```markdown
# Risk Check Prompt v1

You are reviewing a draft outreach reply or post for the PlotLens founder. Score the draft on a 0-100 risk scale.

- **0-20**: Safe to auto-quick-approve. No claims about features that don't exist, no pricing, no competitor mentions, no controversial takes, no apology-style replies, no spam patterns.
- **21-50**: Needs human review but probably fine.
- **51-100**: Flag for careful review. Examples: mentions specific roadmap features, makes a quantitative product claim, replies to a sensitive topic (mental health, harassment, AI ethics debate), uses absolute language ("always", "best", "only").

## Draft

Platform: {{recommended_destination}}
Variant: {{variant}}
Text:
> {{draft_text}}

## Source context

> {{source_excerpt}}

## Output

Return JSON:

```json
{
  "risk_score": <integer 0-100>,
  "reasons": ["short phrase", "..."]
}
```

Only return the JSON. No prose around it.
```

- [ ] **Step 3: Commit**

```bash
git add apps/outreach-workflows/prompts/
git commit -m "feat(outreach-workflows): commit draft and risk-check prompts v1"
```

### Task 24: Workflow B — Draft (call Anthropic, parse, insert 3 drafts)

**Files:**
- Create: `apps/outreach-workflows/n8n/draft.json` (exported)

- [ ] **Step 1: In n8n UI, create workflow `outreach-draft`** with these nodes:

1. **Schedule Trigger** — every 5 minutes
2. **Postgres** (credential `outreach-db-n8n`) — fetch up to 10 candidates and set them to `drafting`:
   ```sql
   UPDATE outreach_items
   SET status='drafting'
   WHERE id IN (
     SELECT id FROM outreach_items
     WHERE status='discovered'
     ORDER BY discovered_at
     LIMIT 10
     FOR UPDATE SKIP LOCKED
   )
   RETURNING id, source_platform, source_url, source_excerpt, source_author, source_community;
   ```
3. **Split In Batches** — process one outreach_item at a time
4. **Set** node — read prompt text from the file `apps/outreach-workflows/prompts/draft-v1.md` and inject template variables. *Note:* n8n doesn't read repo files directly. Two implementation options:
   - (a) Paste the prompt body into the Set node as a multi-line string with `{{ ... }}` placeholders interpolated from the Postgres row.
   - (b) Host the prompt via an n8n static-data ref or HTTP fetch from a public-internal URL.
   For v1, use option (a): copy the prompt text from the file into the Set node verbatim. The audit doesn't enforce prompt-file fidelity (yet); we trust the engineer to keep them in sync via commit discipline.
5. **HTTP Request** (or LangChain Anthropic) node — credential `anthropic-api-key`:
   - Model: `claude-sonnet-4-6`
   - Max tokens: 4000
   - System: "You output only valid JSON, no surrounding prose."
   - User: `={{$json.prompt}}`
   - JSON response parsing enabled
6. **Function** — validate the JSON shape (has `drafts` array length 3, each has `variant` and `draft_text`). Throw on malformed output.
7. **Item Lists → Split Out** the `drafts` array so we have one execution per variant.
8. (T25 adds the risk-check call here.)
9. **Function** — compute `content_hash`:
   ```javascript
   const crypto = require('crypto');
   const text = $json.draft_text;
   const destination = $json.recommended_destination;
   const postType = $json.suggested_post_type || destination.split('_')[1] || 'post';
   const hash = crypto.createHash('sha256').update(text + destination + postType).digest('hex');
   return [{json: {...$json, content_hash: hash, suggested_post_type: postType}}];
   ```
10. **Postgres** (credential `outreach-db-n8n`) — insert draft:
    ```sql
    INSERT INTO drafts (
      outreach_item_id, variant, model_provider, model_name, prompt_version,
      draft_text, suggested_destination, suggested_post_type,
      risk_flags, risk_score, manual_only, content_hash
    ) VALUES ($1, $2, 'anthropic', 'claude-sonnet-4-6', 'draft-v1.md', $3, $4, $5, $6::jsonb, $7, $8, $9);
    ```
11. **Postgres** — after all three variants for one item are inserted, set `outreach_items.status='drafted'` for that id.

- [ ] **Step 2: Smoke-test**

Manually trigger the workflow. Verify:
- 3 `drafts` rows appear per `outreach_items` row processed.
- `outreach_items.status='drafted'` after.
- `drafts.content_hash` is a 64-char hex string.

- [ ] **Step 3: Export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/draft.json"
scp root@192.168.1.80:/tmp/draft.json apps/outreach-workflows/n8n/draft.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
# expect: draft.json now clean
git add apps/outreach-workflows/n8n/draft.json
git commit -m "feat(outreach-workflows): add Draft workflow with Anthropic Sonnet 4.6"
```

### Task 25: Workflow B — second-pass risk check (Haiku)

**Files:**
- Modify: `apps/outreach-workflows/n8n/draft.json` (re-export)

- [ ] **Step 1: In n8n UI, add a second Anthropic call to `outreach-draft`**

After the variant Split Out node and before the content_hash Function node:

1. **Set** — inject the risk-check prompt (paste body from `apps/outreach-workflows/prompts/risk-check-v1.md`) with the variant's `draft_text` and source context.
2. **HTTP Request / LangChain Anthropic** — credential `anthropic-api-key`:
   - Model: `claude-haiku-4-5-20251001`
   - Max tokens: 500
   - JSON output parsing on
3. **Function** — extract `risk_score` and store on the item:
   ```javascript
   const risk = $json.risk_score;
   if (typeof risk !== 'number' || risk < 0 || risk > 100) {
     return [{json: {...$json, risk_score: 75}}];  // unparseable → conservative default
   }
   return [{json: {...$json, risk_score: risk}}];
   ```

- [ ] **Step 2: Update the Postgres insert in step 10 of T24 to use this risk_score** (it should already reference `$json.risk_score`).

- [ ] **Step 3: Smoke-test**

Trigger the workflow on a new outreach_item. Verify `drafts.risk_score` is set to a sensible value (0-100), not the default 50, for at least most rows.

- [ ] **Step 4: Re-export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/draft.json"
scp root@192.168.1.80:/tmp/draft.json apps/outreach-workflows/n8n/draft.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
git add apps/outreach-workflows/n8n/draft.json
git commit -m "feat(outreach-workflows): add Haiku second-pass risk scoring to Draft workflow"
```

### Task 26: Workflow C — Review (Slack notification half)

**Files:**
- Create: `apps/outreach-workflows/n8n/review.json` (initial export)

- [ ] **Step 1: In n8n UI, create workflow `outreach-review-notify`** with these nodes:

1. **Schedule Trigger** — every 2 minutes
2. **Postgres** (credential `outreach-db-n8n`) — find outreach_items needing notification (one notification per item, not per variant — the form will show all three variants side-by-side):
   ```sql
   SELECT oi.id AS outreach_item_id, oi.source_url, oi.source_platform,
          d.id AS preview_draft_id, d.draft_text AS preview_text, d.risk_score AS preview_risk_score,
          d.suggested_destination
   FROM outreach_items oi
   JOIN drafts d ON d.outreach_item_id = oi.id AND d.variant = 'helpful_only'
   WHERE oi.status='drafted'
     AND d.status='needs_human_review'
     AND oi.id NOT IN (
       SELECT (notes::jsonb->>'outreach_item_id')::bigint
       FROM outcomes
       WHERE notes::jsonb ? 'outreach_item_id' AND notes::jsonb->>'kind' = 'notified'
     )
   ORDER BY oi.discovered_at
   LIMIT 5;
   ```
   *Note:* We use `outcomes` as a lightweight notification log to avoid re-notifying. (In Phase 2 this becomes its own `notifications` table; for Phase 1 we squat on `outcomes` with a `{outreach_item_id, kind: notified}` JSON note.)
3. **Split In Batches** — one notification at a time
4. **Slack** (credential `slack-bot-token`) — post to channel:
   - Channel: `{{$env.SLACK_OUTREACH_CHANNEL_ID}}` (set via n8n env vars, value from Infisical)
   - Blocks (Block Kit JSON):
     ```json
     [
       {"type": "section", "text": {"type": "mrkdwn", "text": ":memo: *Outreach item #{{$json.outreach_item_id}}* — `{{$json.source_platform}}` — risk *{{$json.preview_risk_score}}/100*\n><{{$json.source_url}}|source>\n>{{$json.preview_text}}"}},
       {"type": "actions", "elements": [
         {"type": "button", "text": {"type": "plain_text", "text": "Approve helpful-only as-drafted"}, "action_id": "approve_{{$json.outreach_item_id}}", "style": "primary"},
         {"type": "button", "text": {"type": "plain_text", "text": "Reject"}, "action_id": "reject_{{$json.outreach_item_id}}", "style": "danger"},
         {"type": "button", "text": {"type": "plain_text", "text": "Open full form"}, "url": "https://n8n.corbello.io/webhook/render-approval-form?outreach_item_id={{$json.outreach_item_id}}"}
       ]}
     ]
     ```
   - Suppress the "Approve … as-drafted" button if `preview_risk_score >= 20` (use an IF node, or build two block variants).
5. **Postgres** — log the notification:
   ```sql
   INSERT INTO outcomes (publish_job_id, notes)
   VALUES (NULL, jsonb_build_object('outreach_item_id', $1::bigint, 'kind', 'notified')::text);
   ```
   *Note:* This is a stub use of the `outcomes` table. Phase 2 promotes `notifications` to its own table; for Phase 1, this avoids one more migration. Add a TODO in the workflow notes.

- [ ] **Step 2: Smoke-test**

Manually trigger after a draft exists. Confirm a Slack message appears in `#plotlens-outreach` with the expected buttons. (Buttons won't do anything yet — wired in T28.)

- [ ] **Step 3: Export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/review.json"
scp root@192.168.1.80:/tmp/review.json apps/outreach-workflows/n8n/review.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
git add apps/outreach-workflows/n8n/review.json
git commit -m "feat(outreach-workflows): add Review workflow Slack notification half"
```

### Task 27: Workflow C — n8n hosted form

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` (re-export with form trigger)

The form workflow can live in the same `outreach-review` workflow (multi-trigger n8n workflows are supported) or as a separate one. For clarity, **keep them in the same workflow file** — one workflow with two triggers (scheduled notification + form trigger).

- [ ] **Step 1: Add a Form Trigger node to `outreach-review`**

- Form Path: `approve-draft`
- Authentication: Basic Auth → credential `n8n-form-auth`
- Form fields (rendered as the approval card):
  - Display Mode: dynamic — populated from the `draft_id` query parameter
  - Use a "Set" node before the form display to fetch the draft + source data

Actually n8n's Form Trigger doesn't support pre-population from query params natively. Workaround: use **two** triggers:

a. A Webhook node at GET `/webhook/render-approval-form?outreach_item_id=<id>` that:
   - Loads all three drafts for the outreach_item + source from DB
   - Returns an HTML form with one textarea per variant (pre-populated with each variant's text), a "chosen variant" dropdown, and submit buttons

b. A Webhook at POST `/webhook/submit-approval` that:
   - Receives the form submission
   - Resolves the chosen variant to the correct `drafts.id`
   - Computes `content_hash` from the text that will actually be used (edited or original)
   - Inserts an `approvals` row
   - Updates `drafts.status`

- [ ] **Step 2: Build the GET render webhook**

Postgres query (before the Function node):
```sql
SELECT d.id, d.variant, d.draft_text, d.risk_score, d.suggested_destination, d.suggested_post_type,
       oi.source_url, oi.source_platform, oi.id AS outreach_item_id
FROM drafts d
JOIN outreach_items oi ON oi.id = d.outreach_item_id
WHERE oi.id = $1::bigint
  AND d.status = 'needs_human_review'
ORDER BY d.variant;
```

Function node response (HTML) — `$json.rows` is the array of three variant rows:
```javascript
const rows = $json.rows;
if (!rows || rows.length === 0) {
  return [{json: {html: '<h1>No pending drafts for this outreach_item</h1>'}, headers: {"Content-Type": "text/html"}}];
}
const item = rows[0];  // source_url + platform are the same for all three
const escapeHtml = (s) => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const variantBlock = (r) => `
  <div style="margin:12px 0;padding:12px;border:1px solid #ddd">
    <h3>${r.variant} <small style="color:#888">risk ${r.risk_score}/100</small></h3>
    <textarea name="text_${r.variant}" rows="6" cols="80">${escapeHtml(r.draft_text)}</textarea>
    <input type="hidden" name="original_text_${r.variant}" value="${escapeHtml(r.draft_text)}">
    <input type="hidden" name="draft_id_${r.variant}" value="${r.id}">
  </div>`;
const html = `<!doctype html>
<html><head><title>Approve outreach item #${item.outreach_item_id}</title></head>
<body style="font-family:system-ui;max-width:900px;margin:20px auto">
  <h1>Outreach item #${item.outreach_item_id}</h1>
  <p><strong>Source:</strong> <a href="${escapeHtml(item.source_url)}">${escapeHtml(item.source_url)}</a></p>
  <p><strong>Platform:</strong> ${escapeHtml(item.source_platform)}</p>
  <form method="POST" action="/webhook/submit-approval">
    <input type="hidden" name="outreach_item_id" value="${item.outreach_item_id}">
    <h2>Variants (edit any, then choose which to approve)</h2>
    ${rows.map(variantBlock).join('')}
    <label>Chosen variant: <select name="chosen_variant">
      ${rows.map(r => `<option value="${r.variant}">${r.variant}</option>`).join('')}
    </select></label><br>
    <label>Approved destination: <input name="approved_destination" value="${escapeHtml(item.suggested_destination)}"></label><br>
    <label>Approved post type: <input name="approved_post_type" value="${escapeHtml(item.suggested_post_type || 'post')}"></label><br>
    <label>Notes: <input name="notes" size="60"></label><br><br>
    <button name="decision" value="approved">Approve chosen variant</button>
    <button name="decision" value="rejected">Reject all</button>
    <button name="decision" value="manual_only">Approve as manual-only</button>
    <button name="decision" value="save_for_later">Save for later</button>
  </form>
</body></html>`;
return [{json: {html}, headers: {"Content-Type": "text/html"}}];
```

(The "approved" button alone covers both as-drafted and edited paths — the submit handler detects whether the textarea was edited by comparing against the hidden `original_text_*` field.)

- [ ] **Step 3: Smoke-test the form renders**

Visit `https://n8n.corbello.io/webhook/render-approval-form?outreach_item_id=<a real id>` in your browser, authenticate, confirm the form renders with all three variants.

- [ ] **Step 4: Re-export and commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/review.json"
scp root@192.168.1.80:/tmp/review.json apps/outreach-workflows/n8n/review.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
git add apps/outreach-workflows/n8n/review.json
git commit -m "feat(outreach-workflows): add hosted approval form to Review workflow"
```

### Task 28: Workflow C — submit handler (writes approvals)

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json`

- [ ] **Step 1: Add POST `/webhook/submit-approval` to the workflow**

Nodes:

1. **Webhook** (POST) — accepts the form submission
2. **Function** — resolve chosen variant, detect edits, recompute content_hash:
   ```javascript
   const crypto = require('crypto');
   const body = $json.body;
   const chosen = body.chosen_variant || 'helpful_only';
   const editedText = body[`text_${chosen}`];
   const originalText = body[`original_text_${chosen}`];
   const chosenDraftId = parseInt(body[`draft_id_${chosen}`], 10);
   const wasEdited = editedText !== originalText;
   const finalText = editedText;  // textarea wins (edited or not)
   const destination = body.approved_destination;
   const postType = body.approved_post_type;
   const hash = crypto.createHash('sha256').update(finalText + destination + postType).digest('hex');

   return [{json: {
     draft_id: chosenDraftId,
     outreach_item_id: parseInt(body.outreach_item_id, 10),
     approved_by: 'jeremy',  // single user in Phase 1; multi-user later
     decision: body.decision,  // 'approved' | 'rejected' | 'manual_only' | 'save_for_later'
     edited_text: wasEdited ? finalText : null,
     approved_destination: destination,
     approved_post_type: postType,
     approved_content_hash: hash,
     approval_notes: body.notes || null,
   }}];
   ```
3. **Postgres** — insert approval:
   ```sql
   INSERT INTO approvals (draft_id, approved_by, decision, edited_text, approved_destination, approved_post_type, approved_content_hash, approval_notes)
   VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
   RETURNING id;
   ```
4. **Postgres** — update statuses. The chosen variant becomes approved/rejected/manual_only; the other two variants of the same outreach_item become rejected (we picked one):
   ```sql
   -- Mark the chosen draft per the decision
   UPDATE drafts SET status = CASE
     WHEN $1::text = 'approved' THEN 'approved'
     WHEN $1::text = 'manual_only' THEN 'approved'  -- Phase 1: same as approved (DM'd for paste)
     WHEN $1::text = 'rejected' THEN 'rejected'
     ELSE status  -- save_for_later: no change
   END
   WHERE id = $2::bigint;

   -- Mark sibling variants as rejected (only when a chosen variant was approved/manual_only/rejected,
   -- not on save_for_later)
   UPDATE drafts SET status='rejected'
   WHERE outreach_item_id = $3::bigint
     AND id <> $2::bigint
     AND status = 'needs_human_review'
     AND $1::text IN ('approved','manual_only','rejected');

   -- Roll up the outreach_item status
   UPDATE outreach_items SET status='reviewed'
   WHERE id = $3::bigint
     AND $1::text IN ('approved','manual_only','rejected');
   ```
   Parameters: `decision`, `chosen_draft_id`, `outreach_item_id`.
5. **Respond to Webhook** — short HTML page confirming "Approval recorded: <id>"

- [ ] **Step 2: Smoke-test end-to-end**

1. Trigger Workflow A with a manual URL
2. Wait for Workflow B to draft (or manually trigger)
3. Wait for Workflow C notification (or manually trigger)
4. Open the form via Slack button URL, approve as-drafted, submit
5. Verify in DB:
   ```sql
   SELECT a.id, a.decision, a.approved_content_hash, d.content_hash AS draft_hash
   FROM approvals a JOIN drafts d ON d.id = a.draft_id ORDER BY a.id DESC LIMIT 1;
   ```
   Hashes should match (for non-edited approvals) and `decision='approved'`.

- [ ] **Step 3: Re-export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/review.json"
scp root@192.168.1.80:/tmp/review.json apps/outreach-workflows/n8n/review.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
git add apps/outreach-workflows/n8n/review.json
git commit -m "feat(outreach-workflows): wire approval form submission to approvals table"
```

### Task 29: Workflow C — Slack interactive quick-approve

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json`

- [ ] **Step 1: Add POST `/webhook/slack-interactive` to the workflow**

Slack sends a urlencoded `payload=` containing JSON. Nodes:

1. **Webhook** (POST) — Slack interactive request URL configured in T19 Step 2
2. **Function** — parse and verify Slack signature:
   ```javascript
   const crypto = require('crypto');
   const slackSigSecret = $env.SLACK_SIGNING_SECRET;
   const ts = $request.headers['x-slack-request-timestamp'];
   const rawBody = $request.body;  // raw body before parsing
   const sigBase = `v0:${ts}:${rawBody}`;
   const expected = 'v0=' + crypto.createHmac('sha256', slackSigSecret).update(sigBase).digest('hex');
   const got = $request.headers['x-slack-signature'];
   if (got !== expected) throw new Error('invalid slack signature');

   const payload = JSON.parse(decodeURIComponent($request.body.split('payload=')[1]));
   const action = payload.actions[0];
   const [verb, outreachItemId] = action.action_id.split('_');
   return [{json: {verb, outreach_item_id: parseInt(outreachItemId, 10), slack_user: payload.user.id}}];
   ```
3. **IF** — branch on `verb === 'approve'`:
   - **Yes branch:** look up the helpful_only draft for `outreach_item_id` (the Slack quick-approve always targets that variant), check `drafts.risk_score < 20`; if so, insert approval as-drafted (reuse logic from T28's submit handler with `decision='approved'`, `edited_text=null`, hash computed from the original draft text + destination + post_type); if not, respond with "Risk too high, open the form".
   - **No branch (verb === 'reject'):** insert approval for the helpful_only draft with `decision='rejected'`.
   In both branches, run the sibling-update SQL from T28 step 1 node 4 so the other variants get marked accordingly.
4. **HTTP Request** — POST back to Slack `response_url` with a confirmation message ("Approved" / "Rejected").

- [ ] **Step 2: Smoke-test**

From a Slack draft notification, click "Approve as-drafted". Verify:
- DB shows new `approvals` row with `decision='approved'`.
- Slack message updates with confirmation.
- Re-clicking the button is idempotent (or harmless — duplicate approvals are blocked at insert via a unique constraint? Phase 1 lets it pass; Phase 2 adds idempotency.)

- [ ] **Step 3: Re-export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/review.json"
scp root@192.168.1.80:/tmp/review.json apps/outreach-workflows/n8n/review.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
git add apps/outreach-workflows/n8n/review.json
git commit -m "feat(outreach-workflows): add Slack quick-approve / reject buttons to Review"
```

### Task 30: Workflow E (Phase 1 stand-in) — expire stale drafts and approvals

**Files:**
- Create: `apps/outreach-workflows/n8n/expire-stale.json`

- [ ] **Step 1: In n8n UI, create workflow `outreach-expire-stale`** with these nodes:

1. **Schedule Trigger** — daily at 03:00 UTC
2. **Postgres** (credential `outreach-db-n8n`) — expire drafts where any approval older than 7 days hasn't moved them out of `needs_human_review`:
   ```sql
   UPDATE drafts
   SET status='expired'
   WHERE status='needs_human_review'
     AND created_at < now() - INTERVAL '14 days';
   ```
   (14 days here = 7 days standard expiry + 7 days grace.)
3. **Postgres** — expire approvals (the trigger already rejects expired approvals at publish time, but explicit status is useful for dashboards):
   ```sql
   UPDATE approvals
   SET decision='rejected', approval_notes=COALESCE(approval_notes,'') || ' [auto-expired]'
   WHERE decision='approved' AND expires_at < now();
   ```
4. **Slack** (credential `slack-bot-token`) — post a summary to `#plotlens-outreach`:
   ```
   :hourglass: Daily expiry: <N> drafts, <M> approvals
   ```

- [ ] **Step 2: Manually trigger once, verify counts in DB.**

- [ ] **Step 3: Export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/expire-stale.json"
scp root@192.168.1.80:/tmp/expire-stale.json apps/outreach-workflows/n8n/expire-stale.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
git add apps/outreach-workflows/n8n/expire-stale.json
git commit -m "feat(outreach-workflows): add daily expire-stale workflow"
```

### Task 31: Manual-publish workflow (Phase 1 publishing path)

**Files:**
- Create: `apps/outreach-workflows/n8n/manual-publish.json`

Phase 1 has no Postiz, so "publishing" means: when an approval is recorded, DM the user the approved text + source URL so they can paste it manually. This validates the approval gate end-to-end without any Postiz dependency.

- [ ] **Step 1: In n8n UI, create workflow `outreach-manual-publish`** with these nodes:

1. **Schedule Trigger** — every 2 minutes
2. **Postgres** (credential `outreach-db-n8n`) — find approvals not yet DM'd (both `approved` and `manual_only` get DM'd in Phase 1 — they're equivalent for manual-paste publishing):
   ```sql
   SELECT a.id, a.draft_id, a.decision, a.edited_text, a.approved_destination, a.approved_content_hash,
          d.draft_text, oi.source_url, oi.source_platform
   FROM approvals a
   JOIN drafts d ON d.id = a.draft_id
   JOIN outreach_items oi ON oi.id = d.outreach_item_id
   WHERE a.decision IN ('approved', 'manual_only')
     AND a.expires_at > now()
     AND a.id NOT IN (SELECT (notes::jsonb->>'approval_id')::bigint FROM outcomes WHERE notes::jsonb ? 'approval_id');
   ```
3. **Function** — choose text (edited or original):
   ```javascript
   const text = $json.edited_text || $json.draft_text;
   return [{json: {...$json, final_text: text}}];
   ```
4. **Slack** (credential `slack-bot-token`) — send DM to your user ID:
   - Channel: your Slack user ID (stored in Infisical as `SLACK_OUTREACH_OPERATOR_USER_ID`)
   - Text: 
     ```
     :outbox_tray: Approval #{{$json.id}} ready to paste
     Destination: {{$json.approved_destination}}
     Source: {{$json.source_url}}
     ---
     {{$json.final_text}}
     ```
5. **Postgres** — log the DM in `outcomes` so we don't re-DM:
   ```sql
   INSERT INTO outcomes (publish_job_id, notes)
   VALUES (NULL, jsonb_build_object('approval_id', $1::bigint, 'kind', 'manual_dm_sent')::text);
   ```

- [ ] **Step 2: Smoke-test**

Approve a draft, wait ~2 minutes, confirm DM appears in Slack with the right text. Re-run the workflow — should not re-DM.

- [ ] **Step 3: Export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/manual-publish.json"
scp root@192.168.1.80:/tmp/manual-publish.json apps/outreach-workflows/n8n/manual-publish.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
git add apps/outreach-workflows/n8n/manual-publish.json
git commit -m "feat(outreach-workflows): add manual-publish Slack DM workflow (Phase 1 publishing path)"
```

### Task 32: Nightly smoke workflow

**Files:**
- Create: `apps/outreach-workflows/n8n/smoke.json`

- [ ] **Step 1: In n8n UI, create workflow `outreach-smoke`** with these nodes:

1. **Schedule Trigger** — daily at 09:00 UTC
2. **HTTP Request** — hit the manual-paste webhook with a known URL using the secret:
   - URL: `https://n8n.corbello.io/webhook/outreach-discover`
   - Headers: `X-Discover-Secret: {{$env.DISCOVER_WEBHOOK_SECRET}}`
   - Body: `{"url": "https://plotlens.ai/smoke-test/" + new Date().toISOString().slice(0,10), "notes": "nightly smoke"}`
3. **Wait** node — 5 minutes
4. **Postgres** — assert the row was processed all the way to `drafted`:
   ```sql
   SELECT id, status FROM outreach_items
   WHERE source_url = $1
     AND status IN ('drafted','reviewed');
   ```
   Expect at least one row.
5. **IF** — if no rows found:
   - **Slack** — post `:rotating_light: Outreach smoke FAILED — manual webhook did not reach drafted status within 5 min`
6. **Postgres** — clean up the smoke test row to keep the table tidy:
   ```sql
   DELETE FROM outreach_items WHERE source_url LIKE 'https://plotlens.ai/smoke-test/%' AND discovered_at < now() - INTERVAL '1 hour';
   ```
   (Cascade deletes its drafts via FK; only run if drafts have no approval — guard with a NOT IN subquery if needed.)

- [ ] **Step 2: Manually trigger, verify the smoke passes the first time.**

- [ ] **Step 3: Export, audit, commit**

```bash
ssh root@192.168.1.80 "pct exec 112 -- n8n export:workflow --id=<id> --output=/tmp/smoke.json"
scp root@192.168.1.80:/tmp/smoke.json apps/outreach-workflows/n8n/smoke.json
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
# All workflow_file_missing violations should now be resolved.
git add apps/outreach-workflows/n8n/smoke.json
git commit -m "feat(outreach-workflows): add nightly smoke workflow"
```

### Task 33: Operational runbooks

**Files:**
- Create: `docs/runbooks/credential-audit.md`
- Create: `docs/runbooks/outreach-db-recovery.md`
- Create: `docs/runbooks/revoke-approval.md`

- [ ] **Step 1: Write `docs/runbooks/credential-audit.md`**

```markdown
# Running the n8n Credential Audit

## What it does

`scripts/n8n/audit_credentials.py` reads `apps/outreach-workflows/credentials-matrix.yaml` and asserts every workflow JSON under `apps/outreach-workflows/n8n/` only references credentials in its allowlist.

## Running locally before pushing

```bash
python -m scripts.n8n.audit_credentials apps/outreach-workflows/
```

Exit 0 = clean. Exit 1 = violations printed to stderr.

## When CI fails on this

The PR's audit job will print the violations. Either:
- Fix the workflow JSON (remove the disallowed credential from the n8n UI and re-export), or
- If the credential genuinely belongs on this workflow now, update `credentials-matrix.yaml` to allow it. Be explicit about *why* in the PR description.

## Adding a new workflow

1. Add an entry to `workflows:` in `credentials-matrix.yaml` with its filename and `allow:` list.
2. Build the workflow in n8n.
3. Export to `apps/outreach-workflows/n8n/<name>.json`.
4. Run the audit locally.
5. Commit.
```

- [ ] **Step 2: Write `docs/runbooks/outreach-db-recovery.md`**

```markdown
# Outreach DB Recovery

## Daily backups location

`s3://cortech/db-backups/outreach/<YYYY-MM-DD>.sql.gz` on MinIO LXC 123.

## Restore procedure

1. Identify the dump:
   ```bash
   mc ls cortech/db-backups/outreach/ | tail -5
   ```
2. Download:
   ```bash
   mc cp cortech/db-backups/outreach/2026-05-19.sql.gz /tmp/
   ```
3. Drop the DB (this is destructive — confirm with team first):
   ```bash
   ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -c 'DROP DATABASE outreach;'"
   ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -c 'CREATE DATABASE outreach;'"
   ssh root@192.168.1.52 "pct exec 114 -- sudo -u postgres psql -d outreach -c 'GRANT ALL ON SCHEMA public TO outreach_admin;'"
   ```
4. Restore:
   ```bash
   gunzip -c /tmp/2026-05-19.sql.gz | psql "$OUTREACH_DB_ADMIN_URL"
   ```
5. Verify trigger is present:
   ```bash
   psql "$OUTREACH_DB_ADMIN_URL" -c "\df+ enforce_approval_match"
   psql "$OUTREACH_DB_ADMIN_URL" -c "\d publish_jobs"  # confirm trg_enforce_approval_match listed
   ```
6. Run the trigger enforcement tests to confirm safety is intact:
   ```bash
   cd apps/outreach-schema && ./db/tests/run_tests.sh
   ```
```

- [ ] **Step 3: Write `docs/runbooks/revoke-approval.md`**

```markdown
# Revoking an Approval Before Its `expires_at`

## When to do this

- The approval was a mistake (wrong text, wrong destination).
- New information makes the post inappropriate before it has been sent.
- An incident requires halting all outbound posting.

## Procedure (single approval)

```bash
psql "$OUTREACH_DB_ADMIN_URL" -c "
  UPDATE approvals
  SET expires_at = now() - INTERVAL '1 second',
      approval_notes = COALESCE(approval_notes,'') || ' [manually revoked at ' || now()::text || ']'
  WHERE id = <APPROVAL_ID>;
"
```

The `enforce_approval_match` trigger will reject any `publish_jobs` row that references this approval, including any that the dispatcher tries to create later.

## Procedure (kill switch — revoke all unsent approvals)

```bash
psql "$OUTREACH_DB_ADMIN_URL" -c "
  UPDATE approvals SET expires_at = now() - INTERVAL '1 second'
  WHERE decision='approved'
    AND id NOT IN (SELECT approval_id FROM publish_jobs WHERE status='published');
"
```

Use sparingly. Coordinate with the team before flipping.
```

- [ ] **Step 4: Commit**

```bash
git add docs/runbooks/credential-audit.md docs/runbooks/outreach-db-recovery.md docs/runbooks/revoke-approval.md
git commit -m "docs(outreach): add credential-audit, db-recovery, and revoke-approval runbooks"
```

### Task 34: Phase 1 exit verification

**Files:**
- No repo changes; this is verification.

- [ ] **Step 1: Process at least 10 outreach items end-to-end**

For at least 10 distinct source URLs (mix of manual webhook + RSS-discovered):
- Verify they flowed to `drafts` with 3 variants each.
- Approve at least 7 (some as-drafted, at least 2 with edits, at least 1 rejected, at least 1 marked manual-only).
- Confirm the manual-publish DM arrived in Slack for every approved one.
- For each, confirm the text in the DM matches `edited_text` (if edited) or `draft_text` (if not).

Capture the counts:
```sql
SELECT
  count(*) FILTER (WHERE status='drafted')   AS items_drafted,
  count(*) FILTER (WHERE status='reviewed')  AS items_reviewed
FROM outreach_items WHERE discovered_at > now() - INTERVAL '14 days';

SELECT decision, count(*) FROM approvals
WHERE approved_at > now() - INTERVAL '14 days'
GROUP BY decision;
```

- [ ] **Step 2: Run the synthetic trigger-bypass test**

```bash
psql "$OUTREACH_DB_ADMIN_URL" <<SQL
-- Try to insert a publish_job for an approval that doesn't exist
INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
VALUES (999999999, 'x', 'plotlens', 'postiz_immediate', 'fake_hash');
SQL
```

Expected: `ERROR: publish_job approval_id=999999999 not found`. Trigger fires correctly.

Now try with a real-but-rejected approval:
```bash
psql "$OUTREACH_DB_ADMIN_URL" <<SQL
-- Pick any rejected approval id from the test run
INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
SELECT id, 'x', 'plotlens', 'postiz_immediate', approved_content_hash
FROM approvals WHERE decision='rejected' LIMIT 1;
SQL
```

Expected: `ERROR: publish_job approval_id=... has decision=rejected, must be approved`.

- [ ] **Step 3: Run the smoke workflow manually and confirm it reports success in Slack.**

- [ ] **Step 4: Tag the release**

```bash
git tag -a outreach-phase1-shipped -m "PlotLens outreach Phase 1 shipped: approval gate end-to-end with manual publishing"
git push origin outreach-phase1-shipped
```

Phase 1 complete. Phase 2 (Postiz + Temporal production) gets its own plan when you're ready to start it.

---

## Out of Scope (Future Plans)

These are explicitly *not* part of this plan; they get their own plans when you're ready:

- **Phase 2:** Postiz + Temporal in production via ArgoCD. Workflow D (publish dispatcher).
- **Phase 3:** listmonk + SES + `plotlens.ai` DNS + SES production access.
- **Phase 4:** Outcome logger (Workflow E with real metrics), UTM attribution, content calendar, Instagram/Threads integration.
- **Cloud migration:** listmonk → AWS App Runner + RDS. Procedure documented; execution deferred until trigger conditions met.

## Self-Review Notes

Reviewed against the spec sections:

- Architecture (component placement): covered T1-T6 + T19-T20 (Slack/n8n setup)
- Data model (5 tables + trigger): covered T7-T13
- Workflow design (A discover, B draft, C review): covered T21-T29
- Phase 0 Temporal spike: covered T1-T3
- Phase 1 deliverables (1-9 from spec): covered T4-T34
- Cloud migration plan: documented as out-of-scope; the manual-publish path in T31 is the Phase 1 publishing equivalent
- Observability: Phase 1 alerts deferred to Phase 2 plan (no Postiz, Temporal, listmonk = no metrics to scrape yet)
- Backups: T33 step 2 documents the recovery path; the backup *job* itself is reused from existing LXC 114 backup job (out of scope)
- Testing strategy: T12, T16, T17, T18, T34 cover schema, audit, and end-to-end smoke; integration smoke per spec
- AC-1 through AC-10: every acceptance criterion has a task that implements it (AC-1: audit script; AC-2/3/9: trigger + tests; AC-4: manual-publish stays the only Phase 1 publishing path; AC-5: deferred Phase 2; AC-6: schema captures every step; AC-7: source_platform CHECK constraint; AC-8: deferred to per-platform integration in Phase 2+; AC-10: audit script + CI)
