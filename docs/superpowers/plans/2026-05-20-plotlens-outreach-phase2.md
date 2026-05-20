# PlotLens Outreach Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Temporal + Postiz to K3s `plotlens-marketing` namespace under ArgoCD, build Workflow D (n8n publish dispatcher), and onboard the first three social channels (Bluesky, Mastodon, r/PlotLens) end-to-end. Phase 1's manual-paste publishing path becomes automated for supported channels.

**Architecture:** Two ArgoCD Applications (`temporal`, `postiz`) sync into a new namespace. Postiz uses its own Postgres on LXC 114 + dedicated in-cluster Redis + MinIO bucket for media. Workflow D (n8n) polls a new `publish_jobs.status='ready'` row, recomputes the content hash for defense-in-depth, calls Postiz's create-post API, and updates status. The `enforce_approval_match` trigger from Phase 1 remains the load-bearing safety primitive.

**Tech Stack:** ArgoCD, Helm (`temporal-server` chart 0.74.0), Kustomize, Traefik IngressRoute, Infisical Operator (`InfisicalSecret` CRD), Postiz (self-hosted), Temporal, PostgreSQL (LXC 114), Redis (StatefulSet), MinIO, n8n 2.9.4, kube-prometheus-stack, Alertmanager.

**Spec:** `docs/superpowers/specs/2026-05-20-plotlens-outreach-phase2-design.md`.

**Branch:** Start a fresh branch `outreach/phase2` cut from main once Phase 1 merges. Until Phase 1 is on main, work on top of `outreach/phase0-phase1` as a continuation; rebase onto main after Phase 1 merges.

---

## File structure (created or modified across all tasks)

```
apps/
  temporal/                                                # NEW
    argocd-application.yaml                                # multi-source: Helm + Kustomize
    values.yaml                                            # temporal-server chart values
    extras/
      kustomization.yaml
      namespace.yaml                                       # creates plotlens-marketing
      infisical-secret.yaml                                # pulls /temporal from Infisical
      ingressroute.yaml                                    # temporal.corbello.io
      servicemonitor.yaml
  postiz/                                                  # NEW
    argocd-application.yaml                                # pure Kustomize
    base/
      kustomization.yaml
      infisical-secret.yaml                                # pulls /postiz from Infisical
      postiz/
        deployment.yaml
        configmap.yaml
        service.yaml
        ingressroute.yaml                                  # postiz.corbello.io
        ingressroute-webhooks.yaml                         # postiz-webhooks.corbello.io
      redis/
        statefulset.yaml
        service.yaml
      servicemonitor.yaml
    overlays/production/
      kustomization.yaml
  outreach-schema/
    db/migrations/
      20260520120000_publish_jobs_phase2_fields.sql        # NEW
      20260520120100_outreach_items_published_status.sql   # NEW
    db/tests/
      publish_jobs_attempt_count_test.sql.sh               # NEW
      outreach_items_published_rollup_test.sql.sh          # NEW
  outreach-workflows/
    credentials-matrix.yaml                                # MODIFY: add publish-dispatcher
    n8n/
      review.json                                          # MODIFY: extend Write Approval CTE
      publish-dispatcher.json                              # NEW: Workflow D export
    tests/workflow-d/                                      # NEW directory
      test_hash_recompute.sh
      test_retry_cap.sh
      test_manual_required_branch.sh

k8s/observability/dashboards/applications/
  plotlens-marketing.json                                  # NEW dashboard ConfigMap

proxy/sites/                                               # NEW NGINX site configs (on LXC 100)
  temporal.corbello.io.conf
  postiz.corbello.io.conf
  postiz-webhooks.corbello.io.conf

docs/
  runbooks/
    postiz-channel-onboarding.md                           # NEW
    postiz-failed-job-recovery.md                          # NEW
    temporal-restart.md                                    # NEW
  superpowers/roadmaps/
    plotlens-outreach.md                                   # NEW living roadmap

.github/workflows/
  outreach-ci.yml                                          # MODIFY: add manifests-lint job
```

Plus operational (out-of-repo) changes documented in plan tasks:
- LXC 114: new databases `postiz`, `temporal` and roles `postiz_app`, `temporal_app`.
- LXC 123: new MinIO bucket `postiz-media` + dedicated `postiz` MinIO user with scoped policy.
- LXC 112: new env vars `POSTIZ_API_KEY`, `POSTIZ_BASE_URL` in n8n systemd drop-in.
- Infisical PlotLens dev: secrets under `/postiz` and `/temporal` paths.
- Cortech proxy LXC 100: three new NGINX site configs + certbot certs.

---

## Task 1: Create the living roadmap doc

Per the spec, the roadmap is a Phase 2 deliverable that survives across phases. Create it now so subsequent tasks update it as they go.

**Files:**
- Create: `docs/superpowers/roadmaps/plotlens-outreach.md`

- [ ] **Step 1: Create the roadmap file**

```bash
mkdir -p docs/superpowers/roadmaps
```

Write `docs/superpowers/roadmaps/plotlens-outreach.md`:

```markdown
# PlotLens Outreach — Living Roadmap

**Last updated:** 2026-05-20

This is the canonical place to look up current status and pending decisions for the PlotLens outreach pipeline. Updated whenever a phase ships or a decision is made that affects a future phase.

## Status snapshot

| Phase | Status | Spec | Plan | Tag |
|---|---|---|---|---|
| Phase 0 — Temporal spike | shipped | n/a | n/a | findings: `docs/runbooks/temporal-spike-findings.md` |
| Phase 1 — Approval gate end-to-end | build complete, operational validation in progress | `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md` | `docs/superpowers/plans/2026-05-19-plotlens-outreach-phase0-and-phase1.md` | (untagged) |
| Phase 2 — Postiz + Temporal in production | planning | `docs/superpowers/specs/2026-05-20-plotlens-outreach-phase2-design.md` | `docs/superpowers/plans/2026-05-20-plotlens-outreach-phase2.md` | — |
| Phase 3 — listmonk + SES | not started | — (spec written when Phase 2 ships) | — | — |
| Phase 4 — Outcome logger + visual channels | not started | — | — | — |
| Cloud migration (listmonk) | contingent | — | — | — |

## Active decisions

(Decisions made and where they're recorded. New entries added during plan execution.)

- ArgoCD pattern for `plotlens-marketing`: one Application per service (Temporal sync-wave 0, Postiz sync-wave 1). See Phase 2 spec §"ArgoCD deployment shape".
- Secrets pattern: Infisical Operator with `InfisicalSecret` CRD (not ESO, not SealedSecrets). Matches the existing `apps/wordpress` pattern.
- Workflow D location: n8n cron, not Temporal. Preserves the security boundary from the original spec (publish dispatcher has Postiz key, never LLM keys).
- Retry policy in Workflow D: `attempt_count < 3` with n8n cron-every-2min as backoff. Reevaluate in Phase 2.1 if Postiz failure modes warrant Temporal-driven retries.
- Reddit comment replies: manual-only forever per AC-4 (any subreddit, including r/PlotLens).
- Reddit original posts to r/PlotLens: allowed via Postiz under `destination_type=owned_community`.

## Open decisions (settle before next phase starts)

### Phase 3 prerequisites
- Which DNS provider hosts `plotlens.ai` (affects DNS-01 challenge config for cert-manager).
- Which SES region.
- Subscriber list segmentation: one global list, or per-persona?

### Phase 4 prerequisites
- Whether to migrate `SLACK_SIGNING_SECRET` and related secrets out of LXC 112 systemd env into n8n Credentials before Phase 4 adds more workflows. (`N8N_BLOCK_ENV_ACCESS_IN_NODE=false` is currently global.)

## Constraints inherited from earlier phases

- `plotlens-marketing` namespace exists from Phase 2; Phases 3-4 add Applications to it, not new namespaces.
- LXC 114 Postgres hosts `outreach`, `postiz`, `temporal` (Phase 2) and `listmonk` (Phase 3). Phase 4 may need pgbouncer if connection count grows.
- ArgoCD `apps/<service>/` pattern locked in; Phase 3 listmonk follows it.
- The `outcomes` table is multi-purpose by Phase 4: Phase 1 uses `kind='notified'` / `kind='manual_dm_sent'`; Phase 4 will use `kind='analytics_<platform>'`. Kind namespace must not collide.
- `enforce_approval_match` trigger is load-bearing — never touch without re-running fixture tests.
- Workflow D's `attempt_count < 3` cap is intentional and simple. Raising it requires Workflow D re-architecture.

## Deferred items

(Things explicitly punted from a phase to a future phase, with the reason.)

- (none yet — populated during Phase 2 execution if anything gets bumped)

## Trigger conditions for non-linear work

### Cloud migration of listmonk (post-Phase 3)
Any one triggers:
1. Subscriber count > ~5,000.
2. Multi-hour homelab outage affects an unsubscribe link.
3. Revenue-impacting product emails flow through listmonk.

Procedure rehearsed during Phase 3; documented at `docs/runbooks/listmonk-cloud-migration.md` (created in Phase 3). Downtime estimate <30 min if rehearsed.

### Workflow D retry policy upgrade
If `publish_jobs.status='failed'` accounts for >5% of Phase 2 traffic over a 7-day window, escalate to Temporal-driven retries (existing Temporal deployment can host the workflow).

---

This file evolves. Edit it as decisions firm up.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/roadmaps/plotlens-outreach.md
git commit -m "docs(outreach): create living roadmap for outreach phases"
```

---

## Task 2: Pre-flight — verify Phase 1 base state

Before any Phase 2 work, confirm Phase 1 is in the state Phase 2 assumes (workflows active, schema migrated, trigger working).

**Files:** (none — verification only)

- [ ] **Step 1: Verify Phase 1 commit base + branch**

```bash
git log --oneline -5
git status
```

Expected: latest commits include `04be196` (runbooks) and the Phase 2 spec commit `7ef2c6f`. Branch `outreach/phase0-phase1`.

- [ ] **Step 2: Verify all 6 Phase 1 n8n workflows active**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"source /root/.nvm/nvm.sh && n8n list:workflow 2>/dev/null | grep outreach\"'"
```

Expected output contains these IDs:
```
dScvr0utReAcHW01|outreach-discover
dRaFtWfOutreach001|outreach-draft
rEv1eWoUtReAcH001|outreach-review-notify
eXp1rEsTaLeWf001|outreach-expire-stale
mAnUaLpUbLiSh0001|outreach-manual-publish
sMoKeOutreachW001|outreach-smoke
```

- [ ] **Step 3: Verify Phase 1 trigger fixture tests pass**

```bash
cd /home/jacorbello/repos/cortech-infra/apps/outreach-schema
./db/tests/run_tests.sh
```

Expected: all 4 fixture tests PASS.

- [ ] **Step 4: Verify audit script passes**

```bash
cd /home/jacorbello/repos/cortech-infra
python3 scripts/n8n/audit_credentials.py apps/outreach-workflows/
echo "exit: $?"
```

Expected: `Audit passed: no credential violations.` exit 0.

If any verification fails, STOP and resolve before continuing.

---

## Task 3: Create Postgres databases for Postiz and Temporal

These DBs live on LXC 114 alongside `outreach`. dbmate is scoped to `outreach`; cluster-level DDL is out-of-band.

**Files:** (none — operational tasks documented inline)

- [ ] **Step 1: Generate two strong passwords**

```bash
POSTIZ_DB_PASS=$(openssl rand -hex 32)
TEMPORAL_DB_PASS=$(openssl rand -hex 32)
echo "POSTIZ_DB_PASS: $POSTIZ_DB_PASS"
echo "TEMPORAL_DB_PASS: $TEMPORAL_DB_PASS"
```

Save these locally for the next steps. Do NOT commit.

- [ ] **Step 2: Create `postiz` DB and role on LXC 114**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -c \\\"CREATE ROLE postiz_app WITH LOGIN PASSWORD '$POSTIZ_DB_PASS';\\\"\""
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -c \\\"CREATE DATABASE postiz OWNER postiz_app;\\\"\""
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -d postiz -c \\\"GRANT ALL ON SCHEMA public TO postiz_app;\\\"\""
```

- [ ] **Step 3: Create `temporal` DB and role on LXC 114**

```bash
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -c \\\"CREATE ROLE temporal_app WITH LOGIN PASSWORD '$TEMPORAL_DB_PASS';\\\"\""
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -c \\\"CREATE DATABASE temporal OWNER temporal_app;\\\"\""
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -d temporal -c \\\"GRANT ALL ON SCHEMA public TO temporal_app;\\\"\""
```

- [ ] **Step 4: Also create the `temporal_visibility` DB** (Temporal needs a separate DB for visibility/analytics queries per its chart defaults)

```bash
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -c \\\"CREATE DATABASE temporal_visibility OWNER temporal_app;\\\"\""
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -d temporal_visibility -c \\\"GRANT ALL ON SCHEMA public TO temporal_app;\\\"\""
```

- [ ] **Step 5: Verify connectivity from workstation**

```bash
PGPASSWORD=$POSTIZ_DB_PASS psql -h 192.168.1.83 -U postiz_app -d postiz -c "SELECT current_database(), current_user;"
PGPASSWORD=$TEMPORAL_DB_PASS psql -h 192.168.1.83 -U temporal_app -d temporal -c "SELECT current_database(), current_user;"
PGPASSWORD=$TEMPORAL_DB_PASS psql -h 192.168.1.83 -U temporal_app -d temporal_visibility -c "SELECT current_database(), current_user;"
```

Each should return the expected DB + user pair.

---

## Task 4: Create MinIO bucket and dedicated user for Postiz

**Files:** (none — operational, documented)

- [ ] **Step 1: SSH into LXC 123 (MinIO) and run mc commands**

The cortech MinIO is on LXC 123. The `mc` admin client should be configured already with alias `cortech`.

```bash
ssh root@192.168.1.52 "pct exec 123 -- mc mb cortech/postiz-media"
```

- [ ] **Step 2: Generate access key for new user**

```bash
POSTIZ_S3_ACCESS=$(openssl rand -hex 12)
POSTIZ_S3_SECRET=$(openssl rand -hex 24)
ssh root@192.168.1.52 "pct exec 123 -- mc admin user add cortech $POSTIZ_S3_ACCESS $POSTIZ_S3_SECRET"
```

- [ ] **Step 3: Create scoped policy and attach**

Build a policy that grants only the `postiz-media/*` bucket:

```bash
cat > /tmp/postiz-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:ListBucket", "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::postiz-media",
        "arn:aws:s3:::postiz-media/*"
      ]
    }
  ]
}
EOF

scp /tmp/postiz-policy.json root@192.168.1.52:/tmp/
ssh root@192.168.1.52 "scp /tmp/postiz-policy.json root@<MINIO_HOST>:/tmp/ 2>/dev/null || pct push 123 /tmp/postiz-policy.json /tmp/postiz-policy.json"
ssh root@192.168.1.52 "pct exec 123 -- mc admin policy create cortech postiz-media-policy /tmp/postiz-policy.json"
ssh root@192.168.1.52 "pct exec 123 -- mc admin policy attach cortech postiz-media-policy --user $POSTIZ_S3_ACCESS"
```

- [ ] **Step 4: Test bucket access with the new user**

```bash
ssh root@192.168.1.52 "pct exec 123 -- mc alias set postiz-test http://localhost:9000 $POSTIZ_S3_ACCESS $POSTIZ_S3_SECRET"
ssh root@192.168.1.52 "pct exec 123 -- mc ls postiz-test/postiz-media/"
```

Expected: no error, empty listing.

Save `POSTIZ_S3_ACCESS` and `POSTIZ_S3_SECRET` for the Infisical step (Task 6).

---

## Task 5: Schema migration — `publish_jobs.attempt_count` + `sent_at`

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260520120000_publish_jobs_phase2_fields.sql`
- Create: `apps/outreach-schema/db/tests/publish_jobs_attempt_count_test.sql.sh`

- [ ] **Step 1: Write the failing test**

Create `apps/outreach-schema/db/tests/publish_jobs_attempt_count_test.sql.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

echo "Test 1: publish_jobs.attempt_count column exists and defaults to 0"
RESULT=$(psql "$ADMIN_URL" -tAc "
  BEGIN;
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash)
  SELECT id, 'test', 'test', 'manual_required', approved_content_hash
  FROM approvals WHERE decision='approved' LIMIT 1
  RETURNING attempt_count;
  ROLLBACK;
")
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
```

```bash
chmod +x apps/outreach-schema/db/tests/publish_jobs_attempt_count_test.sql.sh
```

- [ ] **Step 2: Run test to verify it fails**

```bash
./apps/outreach-schema/db/tests/publish_jobs_attempt_count_test.sql.sh
```

Expected: FAIL with column not existing.

- [ ] **Step 3: Write the migration**

Create `apps/outreach-schema/db/migrations/20260520120000_publish_jobs_phase2_fields.sql`:

```sql
-- migrate:up
ALTER TABLE publish_jobs
  ADD COLUMN attempt_count INT NOT NULL DEFAULT 0,
  ADD COLUMN sent_at TIMESTAMPTZ;

-- migrate:down
ALTER TABLE publish_jobs
  DROP COLUMN sent_at,
  DROP COLUMN attempt_count;
```

- [ ] **Step 4: Apply migration**

```bash
cd apps/outreach-schema
dbmate up
```

Expected: `Applying: 20260520120000_publish_jobs_phase2_fields.sql`.

- [ ] **Step 5: Re-run test**

```bash
./db/tests/publish_jobs_attempt_count_test.sql.sh
```

Expected: All tests PASS.

- [ ] **Step 6: Re-run Phase 1 trigger fixture tests (regression check)**

```bash
./db/tests/run_tests.sh
```

Expected: all 4 Phase 1 tests still PASS.

- [ ] **Step 7: Commit**

```bash
cd /home/jacorbello/repos/cortech-infra
git add apps/outreach-schema/db/migrations/20260520120000_publish_jobs_phase2_fields.sql \
        apps/outreach-schema/db/tests/publish_jobs_attempt_count_test.sql.sh \
        apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add publish_jobs.attempt_count and sent_at"
```

---

## Task 6: Schema migration — add `'published'` to outreach_items.status enum

**Files:**
- Create: `apps/outreach-schema/db/migrations/20260520120100_outreach_items_published_status.sql`
- Create: `apps/outreach-schema/db/tests/outreach_items_published_rollup_test.sql.sh`

- [ ] **Step 1: Find the existing CHECK constraint name**

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
psql "$ADMIN_URL" -c "\d outreach_items" | grep -i check
```

Note the constraint name (likely `outreach_items_status_check`).

- [ ] **Step 2: Write the failing test**

Create `apps/outreach-schema/db/tests/outreach_items_published_rollup_test.sql.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

echo "Test 1: outreach_items.status accepts 'published'"
RESULT=$(psql "$ADMIN_URL" -tAc "
  BEGIN;
  INSERT INTO outreach_items (source_platform, source_url, status)
  VALUES ('test', 'https://example.com/published-test', 'published')
  RETURNING status;
  ROLLBACK;
" 2>&1)
if [[ "$RESULT" != *"published"* ]]; then
  echo "FAIL: status='published' rejected: $RESULT"
  exit 1
fi
echo "PASS: outreach_items.status accepts 'published'"

echo "Test 2: status='garbage' still rejected"
set +e
RESULT=$(psql "$ADMIN_URL" -tAc "
  INSERT INTO outreach_items (source_platform, source_url, status)
  VALUES ('test', 'https://example.com/garbage-test', 'garbage')
  RETURNING status;
" 2>&1)
set -e
if [[ "$RESULT" != *"violates check constraint"* ]]; then
  echo "FAIL: invalid status not rejected: $RESULT"
  exit 1
fi
echo "PASS: invalid status rejected"

echo "All tests PASS"
```

```bash
chmod +x apps/outreach-schema/db/tests/outreach_items_published_rollup_test.sql.sh
```

- [ ] **Step 3: Run test to confirm it fails**

```bash
./apps/outreach-schema/db/tests/outreach_items_published_rollup_test.sql.sh
```

Expected: Test 1 FAILs (status='published' not in current CHECK).

- [ ] **Step 4: Write the migration**

Create `apps/outreach-schema/db/migrations/20260520120100_outreach_items_published_status.sql` (replace `<EXISTING_CHECK_NAME>` with the name from Step 1):

```sql
-- migrate:up
ALTER TABLE outreach_items DROP CONSTRAINT <EXISTING_CHECK_NAME>;
ALTER TABLE outreach_items ADD CONSTRAINT outreach_items_status_check
  CHECK (status IN ('discovered','drafting','drafted','reviewed','published','expired'));

-- migrate:down
ALTER TABLE outreach_items DROP CONSTRAINT outreach_items_status_check;
ALTER TABLE outreach_items ADD CONSTRAINT <EXISTING_CHECK_NAME>
  CHECK (status IN ('discovered','drafting','drafted','reviewed','expired'));
```

(The migration's down restores the old constraint name + values exactly. Both names should match what Step 1 returned.)

- [ ] **Step 5: Apply migration**

```bash
cd apps/outreach-schema
dbmate up
```

- [ ] **Step 6: Re-run test**

```bash
./db/tests/outreach_items_published_rollup_test.sql.sh
```

Expected: All tests PASS.

- [ ] **Step 7: Re-run Phase 1 trigger fixture tests**

```bash
./db/tests/run_tests.sh
```

Expected: all 4 Phase 1 tests still PASS.

- [ ] **Step 8: Commit**

```bash
cd /home/jacorbello/repos/cortech-infra
git add apps/outreach-schema/db/migrations/20260520120100_outreach_items_published_status.sql \
        apps/outreach-schema/db/tests/outreach_items_published_rollup_test.sql.sh \
        apps/outreach-schema/db/schema.sql
git commit -m "feat(outreach-schema): add 'published' to outreach_items.status enum"
```

---

## Task 7: Store Postiz + Temporal secrets in Infisical

**Files:** (none — secrets land in Infisical, not the repo)

- [ ] **Step 1: Generate Postiz application secrets**

```bash
POSTIZ_JWT_SECRET=$(openssl rand -base64 32 | tr -d '=' | tr '/+' '_-')
POSTIZ_ADMIN_PASSWORD=$(openssl rand -base64 24)
# POSTIZ_DB_PASS, POSTIZ_S3_ACCESS, POSTIZ_S3_SECRET were generated in Tasks 3 & 4
```

- [ ] **Step 2: Write Postiz secrets to Infisical under `/postiz` path**

```bash
PROJECT=db72a923-3cd8-4636-b1ff-80845dc070ca

infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_DATABASE_URL=postgres://postiz_app:${POSTIZ_DB_PASS}@192.168.1.83:5432/postiz?sslmode=disable"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_REDIS_URL=redis://postiz-redis.plotlens-marketing.svc.cluster.local:6379"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_JWT_SECRET=${POSTIZ_JWT_SECRET}"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_ADMIN_PASSWORD=${POSTIZ_ADMIN_PASSWORD}"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_MINIO_ACCESS_KEY=${POSTIZ_S3_ACCESS}"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_MINIO_SECRET_KEY=${POSTIZ_S3_SECRET}"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_MAIN_URL=https://postiz.corbello.io"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_FRONTEND_URL=https://postiz.corbello.io"
infisical secrets set --projectId=$PROJECT --env=dev --path=/postiz \
  "POSTIZ_NEXT_PUBLIC_BACKEND_URL=https://postiz.corbello.io/api"
```

`POSTIZ_API_KEY` is created in Task 12 (after Postiz is running and admin UI generates one).

- [ ] **Step 3: Write Temporal secrets to Infisical under `/temporal` path**

```bash
infisical secrets set --projectId=$PROJECT --env=dev --path=/temporal \
  "TEMPORAL_DATABASE_PASSWORD=${TEMPORAL_DB_PASS}"
```

(The Temporal Helm chart takes the password separately from the host/port/db, so we pass the password only as a secret and the rest as values.yaml.)

- [ ] **Step 4: Verify**

```bash
infisical secrets --projectId=$PROJECT --env=dev --path=/postiz | head -15
infisical secrets --projectId=$PROJECT --env=dev --path=/temporal
```

Expected: secrets present, values masked or visible per CLI defaults.

---

## Task 8: Author `apps/temporal/` skeleton + values.yaml

**Files:**
- Create: `apps/temporal/values.yaml`
- Create: `apps/temporal/extras/kustomization.yaml`
- Create: `apps/temporal/extras/namespace.yaml`
- Create: `apps/temporal/extras/infisical-secret.yaml`
- Create: `apps/temporal/extras/ingressroute.yaml`
- Create: `apps/temporal/extras/servicemonitor.yaml`

- [ ] **Step 1: Create namespace manifest**

`apps/temporal/extras/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: plotlens-marketing
  labels:
    app.kubernetes.io/part-of: plotlens-marketing
```

- [ ] **Step 2: Create InfisicalSecret manifest**

`apps/temporal/extras/infisical-secret.yaml`:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: temporal-secrets
  namespace: plotlens-marketing
spec:
  hostAPI: http://infisical.infisical.svc.cluster.local
  syncConfig:
    resyncInterval: "60s"
  authentication:
    universalAuth:
      secretsScope:
        projectId: db72a923-3cd8-4636-b1ff-80845dc070ca
        envSlug: dev
        secretsPath: /temporal
      credentialsRef:
        secretName: infisical-machine-identity
        secretNamespace: infisical-operator
  managedSecretReference:
    secretName: temporal-secrets
    secretNamespace: plotlens-marketing
    secretType: Opaque
    creationPolicy: Orphan
```

- [ ] **Step 3: Create IngressRoute manifest**

`apps/temporal/extras/ingressroute.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: temporal-ui
  namespace: plotlens-marketing
  labels:
    app: temporal
    app.kubernetes.io/part-of: plotlens-marketing
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`temporal.corbello.io`)
      kind: Rule
      services:
        - name: temporal-web
          port: 8080
```

(Service name `temporal-web` is what the temporal-server chart creates by default for the UI.)

- [ ] **Step 4: Create ServiceMonitor manifest**

`apps/temporal/extras/servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: temporal
  namespace: plotlens-marketing
  labels:
    release: prometheus  # match the kube-prometheus-stack selector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: history
      app.kubernetes.io/name: temporal
  endpoints:
    - port: metrics
      interval: 30s
  namespaceSelector:
    matchNames:
      - plotlens-marketing
```

(The temporal-server chart exposes metrics on each component; this scrapes the history service which is representative.)

- [ ] **Step 5: Create extras kustomization.yaml**

`apps/temporal/extras/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - infisical-secret.yaml
  - ingressroute.yaml
  - servicemonitor.yaml
```

- [ ] **Step 6: Create Helm values.yaml**

`apps/temporal/values.yaml`:

```yaml
# Temporal server values for plotlens-marketing namespace.
# Chart pin: temporal-server 0.74.0 (validated in Phase 0 spike).

server:
  replicaCount: 1
  config:
    persistence:
      default:
        driver: sql
        sql:
          driver: postgres12
          host: 192.168.1.83
          port: 5432
          database: temporal
          user: temporal_app
          existingSecret: temporal-secrets
          existingSecretKey: TEMPORAL_DATABASE_PASSWORD
          maxConns: 20
          maxIdleConns: 20
          maxConnLifetime: "1h"
      visibility:
        driver: sql
        sql:
          driver: postgres12
          host: 192.168.1.83
          port: 5432
          database: temporal_visibility
          user: temporal_app
          existingSecret: temporal-secrets
          existingSecretKey: TEMPORAL_DATABASE_PASSWORD
          maxConns: 10
          maxIdleConns: 10
          maxConnLifetime: "1h"

cassandra:
  enabled: false  # using Postgres backend

mysql:
  enabled: false

prometheus:
  enabled: false  # we use the existing kube-prometheus-stack via ServiceMonitor

grafana:
  enabled: false

elasticsearch:
  enabled: false

web:
  enabled: true
  replicaCount: 1
  service:
    type: ClusterIP
    port: 8080

# Required per Phase 0 spike findings
schema:
  setup:
    enabled: true
  update:
    enabled: true

# Required per Phase 0 spike findings (Sprig templating support)
# This sets the chart-level config file path resolution
setConfigFilePath: true
configMapsToMount:
  - sprig

resources:
  # From Phase 0 spike — adjust if 'temporal-spike-findings.md' has different numbers
  history:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 1Gi
  matching:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
  frontend:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
  worker:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
```

(If `docs/runbooks/temporal-spike-findings.md` lists different resource numbers, use those. Open the spike findings doc and copy the recommended values.)

- [ ] **Step 7: Commit (without the Application yet)**

```bash
cd /home/jacorbello/repos/cortech-infra
git add apps/temporal/values.yaml apps/temporal/extras/
git commit -m "feat(temporal): add manifests and Helm values for plotlens-marketing namespace"
```

---

## Task 9: Create `apps/temporal/argocd-application.yaml` (multi-source)

**Files:**
- Create: `apps/temporal/argocd-application.yaml`

- [ ] **Step 1: Write the Application manifest**

`apps/temporal/argocd-application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: temporal
  namespace: argocd
spec:
  project: default
  sources:
    # Source 1: Helm chart from temporal.io
    - repoURL: https://go.temporal.io/helm-charts
      chart: temporal
      targetRevision: 0.74.0
      helm:
        releaseName: temporal
        valueFiles:
          - $values/apps/temporal/values.yaml
    # Source 2: Plain manifests from this repo (extras: namespace, IngressRoute, etc.)
    - repoURL: https://github.com/jacorbello/cortech-infra.git
      targetRevision: HEAD
      path: apps/temporal/extras
    # Source 3 (ref): same git repo but referenced as ref for $values resolution
    - repoURL: https://github.com/jacorbello/cortech-infra.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: plotlens-marketing
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
    # Sync-wave 0 — Temporal must be healthy before Postiz syncs
  info:
    - name: "sync-wave"
      value: "0"
```

- [ ] **Step 2: Commit**

```bash
git add apps/temporal/argocd-application.yaml
git commit -m "feat(temporal): add ArgoCD Application (multi-source, sync-wave 0)"
```

- [ ] **Step 3: Apply the Application (this triggers ArgoCD to deploy Temporal)**

ArgoCD doesn't auto-discover new Application manifests in this repo (they're not in an app-of-apps yet). Apply manually:

```bash
ssh root@192.168.1.52 "kubectl apply -f /tmp/temporal-application.yaml --validate=false"
```

First copy the manifest to the master:

```bash
scp apps/temporal/argocd-application.yaml root@192.168.1.52:/tmp/
ssh root@192.168.1.52 "kubectl apply -f /tmp/argocd-application.yaml"
```

- [ ] **Step 4: Watch sync progress**

```bash
ssh root@192.168.1.52 "kubectl get application temporal -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}' && echo"
```

Repeat every 30 seconds until output reads `Synced Healthy`. Expect 3-7 minutes for first deploy (schema setup runs on first start).

- [ ] **Step 5: Verify Temporal pods**

```bash
ssh root@192.168.1.52 "kubectl get pods -n plotlens-marketing"
```

Expected: `temporal-frontend`, `temporal-history`, `temporal-matching`, `temporal-worker`, `temporal-web` all `Running`.

- [ ] **Step 6: Verify Temporal DB schema was set up**

```bash
ADMIN_URL="postgres://temporal_app:${TEMPORAL_DB_PASS}@192.168.1.83:5432/temporal"
psql "$ADMIN_URL" -c "\dt" | head
```

Expected: tables like `executions`, `current_executions`, `namespace_metadata`, etc.

If `\dt` is empty, the schema setup job didn't run. Check:
```bash
ssh root@192.168.1.52 "kubectl logs -n plotlens-marketing job/temporal-schema-setup"
```

---

## Task 10: NGINX proxy site config for `temporal.corbello.io`

The cortech proxy LXC 100 terminates TLS for all `*.corbello.io` traffic and forwards to the K3s Traefik. Add a new site for the Temporal UI.

**Files:**
- Create: `proxy/sites/temporal.corbello.io.conf` (on LXC 100, also committed to this repo)

- [ ] **Step 1: Check existing site configs for the pattern**

```bash
ssh root@192.168.1.52 "pct exec 100 -- ls /etc/nginx/sites-available/ | head"
ssh root@192.168.1.52 "pct exec 100 -- cat /etc/nginx/sites-available/<one-existing-site>.conf"
```

Pick any existing `*.corbello.io` site and use it as a template (e.g., `rancher.corbello.io.conf` or `harbor.corbello.io.conf`).

- [ ] **Step 2: Create the new site config**

`proxy/sites/temporal.corbello.io.conf`:

```nginx
server {
    listen 443 ssl http2;
    server_name temporal.corbello.io;

    ssl_certificate /etc/letsencrypt/live/temporal.corbello.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/temporal.corbello.io/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Standard security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    # Forward to K3s Traefik via the cluster API VIP
    location / {
        proxy_pass http://192.168.1.90:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
}

server {
    listen 80;
    server_name temporal.corbello.io;
    return 301 https://$host$request_uri;
}
```

- [ ] **Step 3: Get Let's Encrypt cert**

```bash
ssh root@192.168.1.52 "pct exec 100 -- certbot certonly --nginx -d temporal.corbello.io --non-interactive --agree-tos -m jacorbello@gmail.com"
```

Expected: cert issued to `/etc/letsencrypt/live/temporal.corbello.io/`.

- [ ] **Step 4: Push the site config to LXC 100**

```bash
scp proxy/sites/temporal.corbello.io.conf root@192.168.1.52:/tmp/
ssh root@192.168.1.52 "pct push 100 /tmp/temporal.corbello.io.conf /etc/nginx/sites-available/temporal.corbello.io.conf"
ssh root@192.168.1.52 "pct exec 100 -- ln -sf /etc/nginx/sites-available/temporal.corbello.io.conf /etc/nginx/sites-enabled/"
ssh root@192.168.1.52 "pct exec 100 -- nginx -t && pct exec 100 -- systemctl reload nginx"
```

- [ ] **Step 5: Smoke-test the URL**

```bash
curl -sI https://temporal.corbello.io/ | head -5
```

Expected: HTTP/2 200 (or HTTP/2 302 redirect to the Temporal UI). Browse `https://temporal.corbello.io` and confirm the Temporal Web UI loads. The Default namespace should be visible.

- [ ] **Step 6: Commit the site config to the repo**

```bash
cd /home/jacorbello/repos/cortech-infra
git add proxy/sites/temporal.corbello.io.conf
git commit -m "feat(proxy): add temporal.corbello.io NGINX site config"
```

---

## Task 11: Author `apps/postiz/` Kustomize base manifests

Postiz doesn't publish an official Helm chart, so we translate its docker-compose into Kubernetes manifests.

**Files:**
- Create: `apps/postiz/base/redis/statefulset.yaml`
- Create: `apps/postiz/base/redis/service.yaml`
- Create: `apps/postiz/base/postiz/configmap.yaml`
- Create: `apps/postiz/base/postiz/deployment.yaml`
- Create: `apps/postiz/base/postiz/service.yaml`
- Create: `apps/postiz/base/postiz/ingressroute.yaml`
- Create: `apps/postiz/base/postiz/ingressroute-webhooks.yaml`
- Create: `apps/postiz/base/infisical-secret.yaml`
- Create: `apps/postiz/base/servicemonitor.yaml`
- Create: `apps/postiz/base/kustomization.yaml`
- Create: `apps/postiz/overlays/production/kustomization.yaml`

- [ ] **Step 1: Redis StatefulSet**

`apps/postiz/base/redis/statefulset.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postiz-redis
  namespace: plotlens-marketing
  labels:
    app: postiz-redis
    app.kubernetes.io/part-of: postiz
spec:
  serviceName: postiz-redis
  replicas: 1
  selector:
    matchLabels:
      app: postiz-redis
  template:
    metadata:
      labels:
        app: postiz-redis
    spec:
      containers:
        - name: redis
          image: redis:7.4-alpine
          ports:
            - name: redis
              containerPort: 6379
          args:
            - "--save"
            - "60"
            - "1"
            - "--appendonly"
            - "yes"
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
          livenessProbe:
            tcpSocket:
              port: redis
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: nfs-csi
        resources:
          requests:
            storage: 5Gi
```

- [ ] **Step 2: Redis Service**

`apps/postiz/base/redis/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postiz-redis
  namespace: plotlens-marketing
  labels:
    app: postiz-redis
    app.kubernetes.io/part-of: postiz
spec:
  type: ClusterIP
  ports:
    - name: redis
      port: 6379
      targetPort: redis
  selector:
    app: postiz-redis
```

- [ ] **Step 3: Postiz ConfigMap (non-secret env)**

`apps/postiz/base/postiz/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postiz-config
  namespace: plotlens-marketing
data:
  STORAGE_PROVIDER: "local"  # Postiz writes media to local fs initially; revisit MinIO after smoke
  IS_GENERAL: "true"          # required per Postiz docs for self-hosted
  NX_ADD_PLUGINS: "true"
  DISABLE_REGISTRATION: "true"  # only admin signs in
  # Postiz reads MinIO config when STORAGE_PROVIDER=cloudflare or s3; revisit when switching
  TZ: "UTC"
```

(MinIO/S3-backed storage in Postiz requires `STORAGE_PROVIDER=cloudflare` with R2-compatible settings. We start with `local` storage for Phase 2 simplicity — bucket `postiz-media` is created and ready but not wired into Postiz until Phase 2.1 when we confirm Postiz S3 compatibility against MinIO. The bucket sits unused; no harm.)

- [ ] **Step 4: Postiz Deployment**

`apps/postiz/base/postiz/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postiz
  namespace: plotlens-marketing
  labels:
    app: postiz
    app.kubernetes.io/part-of: postiz
spec:
  replicas: 1
  strategy:
    type: Recreate  # avoid two instances stomping the DB during rolling update
  selector:
    matchLabels:
      app: postiz
  template:
    metadata:
      labels:
        app: postiz
    spec:
      containers:
        - name: postiz
          image: ghcr.io/gitroomhq/postiz-app:latest  # consider pinning to a specific SHA after first deploy
          ports:
            - name: http
              containerPort: 5000   # Postiz frontend
            - name: api
              containerPort: 3000   # Postiz backend API
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: postiz-secrets
                  key: POSTIZ_DATABASE_URL
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: postiz-secrets
                  key: POSTIZ_REDIS_URL
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: postiz-secrets
                  key: POSTIZ_JWT_SECRET
            - name: MAIN_URL
              valueFrom:
                secretKeyRef:
                  name: postiz-secrets
                  key: POSTIZ_MAIN_URL
            - name: FRONTEND_URL
              valueFrom:
                secretKeyRef:
                  name: postiz-secrets
                  key: POSTIZ_FRONTEND_URL
            - name: NEXT_PUBLIC_BACKEND_URL
              valueFrom:
                secretKeyRef:
                  name: postiz-secrets
                  key: POSTIZ_NEXT_PUBLIC_BACKEND_URL
          envFrom:
            - configMapRef:
                name: postiz-config
          volumeMounts:
            - name: media
              mountPath: /app/uploads
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 2Gi
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 60
            periodSeconds: 30
      volumes:
        - name: media
          persistentVolumeClaim:
            claimName: postiz-media
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postiz-media
  namespace: plotlens-marketing
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 20Gi
```

- [ ] **Step 5: Postiz Service**

`apps/postiz/base/postiz/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postiz
  namespace: plotlens-marketing
  labels:
    app: postiz
    app.kubernetes.io/part-of: postiz
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 5000
      targetPort: http
    - name: api
      port: 3000
      targetPort: api
  selector:
    app: postiz
```

- [ ] **Step 6: Postiz IngressRoute (admin UI)**

`apps/postiz/base/postiz/ingressroute.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: postiz
  namespace: plotlens-marketing
  labels:
    app: postiz
    app.kubernetes.io/part-of: postiz
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`postiz.corbello.io`)
      kind: Rule
      services:
        - name: postiz
          port: 5000
    - match: Host(`postiz.corbello.io`) && PathPrefix(`/api`)
      kind: Rule
      services:
        - name: postiz
          port: 3000
```

- [ ] **Step 7: Postiz IngressRoute (webhook callbacks)**

`apps/postiz/base/postiz/ingressroute-webhooks.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: postiz-webhooks
  namespace: plotlens-marketing
  labels:
    app: postiz
    app.kubernetes.io/part-of: postiz
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`postiz-webhooks.corbello.io`)
      kind: Rule
      services:
        - name: postiz
          port: 3000  # backend API receives provider webhooks
```

- [ ] **Step 8: InfisicalSecret**

`apps/postiz/base/infisical-secret.yaml`:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: postiz-secrets
  namespace: plotlens-marketing
spec:
  hostAPI: http://infisical.infisical.svc.cluster.local
  syncConfig:
    resyncInterval: "60s"
  authentication:
    universalAuth:
      secretsScope:
        projectId: db72a923-3cd8-4636-b1ff-80845dc070ca
        envSlug: dev
        secretsPath: /postiz
      credentialsRef:
        secretName: infisical-machine-identity
        secretNamespace: infisical-operator
  managedSecretReference:
    secretName: postiz-secrets
    secretNamespace: plotlens-marketing
    secretType: Opaque
    creationPolicy: Orphan
```

- [ ] **Step 9: ServiceMonitor**

`apps/postiz/base/servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postiz
  namespace: plotlens-marketing
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: postiz
  endpoints:
    - port: api
      path: /metrics
      interval: 30s
  namespaceSelector:
    matchNames:
      - plotlens-marketing
```

(Postiz exposes Prom metrics on its API port at `/metrics` per the docs — verify with `curl postiz.corbello.io/api/metrics` after deploy. If the path is different, update this.)

- [ ] **Step 10: base/kustomization.yaml**

`apps/postiz/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: plotlens-marketing
resources:
  - infisical-secret.yaml
  - redis/statefulset.yaml
  - redis/service.yaml
  - postiz/configmap.yaml
  - postiz/deployment.yaml
  - postiz/service.yaml
  - postiz/ingressroute.yaml
  - postiz/ingressroute-webhooks.yaml
  - servicemonitor.yaml
```

(No namespace.yaml — namespace was created by the `temporal` Application.)

- [ ] **Step 11: overlays/production/kustomization.yaml**

`apps/postiz/overlays/production/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: plotlens-marketing
resources:
  - ../../base
```

(Phase 2 has no overlay-specific changes; the overlay exists to match the `apps/wordpress` pattern.)

- [ ] **Step 12: Commit base manifests**

```bash
cd /home/jacorbello/repos/cortech-infra
git add apps/postiz/base/ apps/postiz/overlays/
git commit -m "feat(postiz): add Kustomize manifests for plotlens-marketing namespace"
```

---

## Task 12: Author `apps/postiz/argocd-application.yaml` and sync

**Files:**
- Create: `apps/postiz/argocd-application.yaml`

- [ ] **Step 1: Write Application manifest**

`apps/postiz/argocd-application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postiz
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jacorbello/cortech-infra.git
    targetRevision: HEAD
    path: apps/postiz/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: plotlens-marketing
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
  info:
    - name: "sync-wave"
      value: "1"
```

- [ ] **Step 2: Commit**

```bash
git add apps/postiz/argocd-application.yaml
git commit -m "feat(postiz): add ArgoCD Application (sync-wave 1)"
```

- [ ] **Step 3: Push the branch so ArgoCD can read it**

If you haven't already pushed Phase 1 + Phase 2 commits, do it now:

```bash
git push -u origin outreach/phase0-phase1
```

(Postiz Application points at HEAD of the repo, so the branch must be reachable on GitHub.)

- [ ] **Step 4: Apply the Application**

```bash
scp apps/postiz/argocd-application.yaml root@192.168.1.52:/tmp/postiz-application.yaml
ssh root@192.168.1.52 "kubectl apply -f /tmp/postiz-application.yaml"
```

- [ ] **Step 5: Watch sync progress**

```bash
ssh root@192.168.1.52 "kubectl get application postiz -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}' && echo"
```

Repeat every 30 seconds. First deploy may take 5-10 min (image pull + DB migrations).

- [ ] **Step 6: Verify pods**

```bash
ssh root@192.168.1.52 "kubectl get pods -n plotlens-marketing"
```

Expected: `postiz-<hash>` running + `postiz-redis-0` running + all the temporal-* pods from Task 9.

- [ ] **Step 7: Check Postiz logs for errors**

```bash
ssh root@192.168.1.52 "kubectl logs -n plotlens-marketing -l app=postiz --tail=50"
```

Look for "Server ready" or similar. Errors like "connection refused" to Redis mean Step 1's StatefulSet isn't ready; wait + retry.

---

## Task 13: NGINX proxy site configs for `postiz.corbello.io` and `postiz-webhooks.corbello.io`

**Files:**
- Create: `proxy/sites/postiz.corbello.io.conf`
- Create: `proxy/sites/postiz-webhooks.corbello.io.conf`

- [ ] **Step 1: Build the Postiz admin site config**

`proxy/sites/postiz.corbello.io.conf`:

```nginx
server {
    listen 443 ssl http2;
    server_name postiz.corbello.io;

    ssl_certificate /etc/letsencrypt/live/postiz.corbello.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/postiz.corbello.io/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;

    client_max_body_size 50m;  # Postiz allows media uploads

    location / {
        proxy_pass http://192.168.1.90:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
}

server {
    listen 80;
    server_name postiz.corbello.io;
    return 301 https://$host$request_uri;
}
```

- [ ] **Step 2: Build the Postiz webhooks site config**

`proxy/sites/postiz-webhooks.corbello.io.conf`:

```nginx
server {
    listen 443 ssl http2;
    server_name postiz-webhooks.corbello.io;

    ssl_certificate /etc/letsencrypt/live/postiz-webhooks.corbello.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/postiz-webhooks.corbello.io/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Webhooks from social providers (X, LinkedIn, etc) — keep simple, no auth here;
    # platform-specific HMAC verification happens inside Postiz.
    location / {
        proxy_pass http://192.168.1.90:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
    }
}

server {
    listen 80;
    server_name postiz-webhooks.corbello.io;
    return 301 https://$host$request_uri;
}
```

- [ ] **Step 3: Issue certificates**

```bash
ssh root@192.168.1.52 "pct exec 100 -- certbot certonly --nginx -d postiz.corbello.io --non-interactive --agree-tos -m jacorbello@gmail.com"
ssh root@192.168.1.52 "pct exec 100 -- certbot certonly --nginx -d postiz-webhooks.corbello.io --non-interactive --agree-tos -m jacorbello@gmail.com"
```

- [ ] **Step 4: Push the configs and reload NGINX**

```bash
scp proxy/sites/postiz.corbello.io.conf proxy/sites/postiz-webhooks.corbello.io.conf root@192.168.1.52:/tmp/
ssh root@192.168.1.52 "pct push 100 /tmp/postiz.corbello.io.conf /etc/nginx/sites-available/postiz.corbello.io.conf"
ssh root@192.168.1.52 "pct push 100 /tmp/postiz-webhooks.corbello.io.conf /etc/nginx/sites-available/postiz-webhooks.corbello.io.conf"
ssh root@192.168.1.52 "pct exec 100 -- ln -sf /etc/nginx/sites-available/postiz.corbello.io.conf /etc/nginx/sites-enabled/"
ssh root@192.168.1.52 "pct exec 100 -- ln -sf /etc/nginx/sites-available/postiz-webhooks.corbello.io.conf /etc/nginx/sites-enabled/"
ssh root@192.168.1.52 "pct exec 100 -- nginx -t && pct exec 100 -- systemctl reload nginx"
```

- [ ] **Step 5: Smoke-test**

```bash
curl -sI https://postiz.corbello.io/ | head -3
curl -sI https://postiz-webhooks.corbello.io/ | head -3
```

Expected: HTTP/2 200 for `postiz.corbello.io` (Postiz login screen).

Visit `https://postiz.corbello.io` in a browser, confirm Postiz login screen loads.

- [ ] **Step 6: Commit**

```bash
cd /home/jacorbello/repos/cortech-infra
git add proxy/sites/postiz.corbello.io.conf proxy/sites/postiz-webhooks.corbello.io.conf
git commit -m "feat(proxy): add postiz.corbello.io and postiz-webhooks.corbello.io site configs"
```

---

## Task 14: First-run Postiz setup + generate API key

**Files:** (none — operational; secret lands in Infisical)

- [ ] **Step 1: Open Postiz UI and create the admin account**

Visit `https://postiz.corbello.io`. The first-run flow prompts for an admin email + password.

Use:
- Email: `jacorbello@gmail.com`
- Password: from Infisical `POSTIZ_ADMIN_PASSWORD`

```bash
infisical secrets get POSTIZ_ADMIN_PASSWORD --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain
```

After login, you should land on the Postiz dashboard.

- [ ] **Step 2: Generate API key**

In Postiz UI → Settings → API Keys → Generate New API Key. Name it `outreach-dispatcher`. Copy the bearer token (one-time view).

- [ ] **Step 3: Save API key to Infisical**

```bash
infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  "POSTIZ_API_KEY=<paste_token_here>"

infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  "POSTIZ_API_BASE_URL=https://postiz.corbello.io/api"
```

- [ ] **Step 4: Smoke-test the API**

```bash
TOKEN=$(infisical secrets get POSTIZ_API_KEY --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)
curl -sS -H "Authorization: Bearer $TOKEN" "https://postiz.corbello.io/api/integrations" | head -100
```

Expected: JSON response (empty array — no integrations yet — or some metadata structure). 401 or 403 means the token is wrong or the auth header format differs; check Postiz docs for the exact format.

---

## Task 15: Update credentials-matrix.yaml — add publish-dispatcher

**Files:**
- Modify: `apps/outreach-workflows/credentials-matrix.yaml`

- [ ] **Step 1: Add publish-dispatcher entry; remove postiz-api-key from forbidden_phase1**

Edit `apps/outreach-workflows/credentials-matrix.yaml` — append after the `smoke` block and before `forbidden_phase1`:

```yaml
  publish-dispatcher:
    file: n8n/publish-dispatcher.json
    allow:
      - outreach-db-n8n
      - postiz-api-key          # Phase 2 — Postiz Create Post API
      # NO LLM credentials. NO Slack. This workflow only calls Postiz.

# Credentials that MUST NEVER appear in any of the above workflows.
# (postiz-api-key is now allowed on publish-dispatcher only; ses-smtp arrives in Phase 3.)
forbidden_phase1:
  - ses-smtp-credentials
```

(Previously `forbidden_phase1` had `postiz-api-key`; it's removed because Phase 2 introduces a workflow that legitimately uses it.)

- [ ] **Step 2: Add a new hard-fail rule: LLM credentials on publish-dispatcher**

The audit script should still hard-fail if any LLM credential lands on publish-dispatcher. The existing audit logic uses the `allow` list (any credential NOT in `allow` is rejected). So adding `anthropic-api-key` to forbidden isn't needed — it's already implicitly forbidden by not being in `publish-dispatcher.allow`.

Verify by reading `scripts/n8n/audit_credentials.py`:

```bash
grep -A 5 "allow" scripts/n8n/audit_credentials.py | head -30
```

If the audit's allow-check is by-credential-name (i.e., any name not in `allow` is rejected), no change is needed. If the audit relies on `forbidden_phase1` only, add an explicit `forbidden_per_workflow` block:

```yaml
forbidden_per_workflow:
  publish-dispatcher:
    - anthropic-api-key
    - openai-api-key
    - slack-bot-token
```

(Adapt the audit script if it doesn't already support this. Inspect first.)

- [ ] **Step 3: Run the audit**

```bash
cd /home/jacorbello/repos/cortech-infra
python3 scripts/n8n/audit_credentials.py apps/outreach-workflows/
```

Expected: ONE failure for `publish-dispatcher` (file missing). Other workflows clean.

This is the intended state — the failure resolves when Workflow D is exported in Task 17.

- [ ] **Step 4: Commit**

```bash
git add apps/outreach-workflows/credentials-matrix.yaml
git commit -m "feat(outreach-workflows): authorize publish-dispatcher to use postiz-api-key"
```

---

## Task 16: Add `POSTIZ_API_KEY` + `POSTIZ_API_BASE_URL` to LXC 112 systemd drop-in

**Files:** (modifies `/etc/systemd/system/n8n.service.d/slack-env.conf` on LXC 112 — not in repo)

- [ ] **Step 1: Add the env vars**

```bash
TOKEN=$(infisical secrets get POSTIZ_API_KEY --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)
BASE=$(infisical secrets get POSTIZ_API_BASE_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)

ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"
  cat >> /etc/systemd/system/n8n.service.d/slack-env.conf <<EOF
Environment=POSTIZ_API_KEY=$TOKEN
Environment=POSTIZ_API_BASE_URL=$BASE
EOF
  systemctl daemon-reload && systemctl restart n8n
\"'"
```

- [ ] **Step 2: Wait for n8n to come back**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- systemctl is-active n8n'"
```

Wait until output `active`. Initial restart can take 30-60 seconds.

- [ ] **Step 3: Verify the env var is visible in n8n's process**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"
  cat /proc/\$(pgrep -f \\\"n8n\\\" | head -1)/environ | tr \\\"\\0\\\" \\\"\\n\\\" | grep POSTIZ
\"'"
```

Expected: two lines, `POSTIZ_API_KEY=...` and `POSTIZ_API_BASE_URL=https://postiz.corbello.io/api`.

---

## Task 17: Build Workflow D in n8n

The plan calls for a JSON-direct authoring approach (mirroring Phase 1's pattern — build the workflow JSON locally, import to n8n, activate). This is faster than UI clicks for a workflow with 11 nodes.

**Files:**
- Create: `apps/outreach-workflows/n8n/publish-dispatcher.json`

- [ ] **Step 1: Create the n8n credential `postiz-api-key`**

In n8n UI (`https://n8n.corbello.io`) → Credentials → New → HTTP Header Auth.
- Name: `postiz-api-key`
- Header name: `Authorization`
- Header value: `Bearer ` + the `POSTIZ_API_KEY` from Infisical

Save. Note the credential ID from the URL (looks like `xK4PqRzM...` — 16-char alphanumeric).

- [ ] **Step 2: Author the workflow JSON**

Create `/tmp/publish-dispatcher.json` with this content (replace `<POSTIZ_CRED_ID>` with the ID from Step 1):

```json
{
  "name": "outreach-publish-dispatcher",
  "active": true,
  "nodes": [
    {
      "parameters": {
        "rule": {
          "interval": [{"field": "minutes", "minutesInterval": 2}]
        }
      },
      "id": "pd0000a1-0001-0000-0000-000000000001",
      "name": "Schedule Trigger",
      "type": "n8n-nodes-base.scheduleTrigger",
      "typeVersion": 1,
      "position": [200, 300]
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "SELECT pj.id AS publish_job_id, pj.approval_id, pj.destination_platform, pj.destination_account, pj.publish_mode, pj.payload_hash, pj.attempt_count, a.approved_content_hash, a.approved_destination, a.approved_post_type, COALESCE(a.edited_text, d.draft_text) AS final_text, d.outreach_item_id FROM publish_jobs pj JOIN approvals a ON a.id = pj.approval_id JOIN drafts d ON d.id = a.draft_id WHERE pj.status = 'ready' AND pj.attempt_count < 3 ORDER BY pj.scheduled_for NULLS FIRST, pj.id LIMIT 20;",
        "options": {}
      },
      "id": "pd0000a2-0001-0000-0000-000000000002",
      "name": "Fetch Ready",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.6,
      "position": [420, 300],
      "credentials": {
        "postgres": {"id": "fOZmso5kyXr6Agdn", "name": "outreach-db-n8n"}
      }
    },
    {
      "parameters": {
        "batchSize": 1,
        "options": {}
      },
      "id": "pd0000a3-0001-0000-0000-000000000003",
      "name": "Split In Batches",
      "type": "n8n-nodes-base.splitInBatches",
      "typeVersion": 3,
      "position": [640, 300]
    },
    {
      "parameters": {
        "mode": "runOnceForEachItem",
        "jsCode": "// SHA-256 pure-JS implementation — same as Phase 1's Build Approval node.\n// require('crypto') is blocked in n8n 2.9.4 task runner.\nfunction sha256(input) {\n  const K = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];\n  let H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];\n  const bytes = [];\n  for (let i = 0; i < input.length; i++) {\n    const c = input.charCodeAt(i);\n    if (c < 0x80) bytes.push(c);\n    else if (c < 0x800) { bytes.push(0xc0|(c>>6)); bytes.push(0x80|(c&0x3f)); }\n    else if (c < 0xd800 || c >= 0xe000) { bytes.push(0xe0|(c>>12)); bytes.push(0x80|((c>>6)&0x3f)); bytes.push(0x80|(c&0x3f)); }\n    else { i++; const c2 = input.charCodeAt(i); const cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff)); bytes.push(0xf0|(cp>>18)); bytes.push(0x80|((cp>>12)&0x3f)); bytes.push(0x80|((cp>>6)&0x3f)); bytes.push(0x80|(cp&0x3f)); }\n  }\n  const bitLen = bytes.length * 8;\n  bytes.push(0x80);\n  while ((bytes.length % 64) !== 56) bytes.push(0);\n  for (let i = 7; i >= 0; i--) bytes.push((bitLen >>> (i*8)) & 0xff);\n  for (let chunk = 0; chunk < bytes.length; chunk += 64) {\n    const W = new Array(64);\n    for (let i = 0; i < 16; i++) W[i] = (bytes[chunk+i*4]<<24)|(bytes[chunk+i*4+1]<<16)|(bytes[chunk+i*4+2]<<8)|bytes[chunk+i*4+3];\n    for (let i = 16; i < 64; i++) {\n      const s0 = ((W[i-15]>>>7)|(W[i-15]<<25)) ^ ((W[i-15]>>>18)|(W[i-15]<<14)) ^ (W[i-15]>>>3);\n      const s1 = ((W[i-2]>>>17)|(W[i-2]<<15)) ^ ((W[i-2]>>>19)|(W[i-2]<<13)) ^ (W[i-2]>>>10);\n      W[i] = (W[i-16] + s0 + W[i-7] + s1) | 0;\n    }\n    let [a,b,c,d,e,f,g,h] = H;\n    for (let i = 0; i < 64; i++) {\n      const S1 = ((e>>>6)|(e<<26)) ^ ((e>>>11)|(e<<21)) ^ ((e>>>25)|(e<<7));\n      const ch = (e & f) ^ (~e & g);\n      const t1 = (h + S1 + ch + K[i] + W[i]) | 0;\n      const S0 = ((a>>>2)|(a<<30)) ^ ((a>>>13)|(a<<19)) ^ ((a>>>22)|(a<<10));\n      const mj = (a & b) ^ (a & c) ^ (b & c);\n      const t2 = (S0 + mj) | 0;\n      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;\n    }\n    H = [(H[0]+a)|0,(H[1]+b)|0,(H[2]+c)|0,(H[3]+d)|0,(H[4]+e)|0,(H[5]+f)|0,(H[6]+g)|0,(H[7]+h)|0];\n  }\n  return H.map(n => (n>>>0).toString(16).padStart(8,'0')).join('');\n}\n\nconst item = $input.item.json;\nconst finalText = item.final_text || '';\nconst destination = item.approved_destination || '';\nconst postType = item.approved_post_type || '';\nconst computedHash = sha256(finalText + destination + postType);\n\nif (computedHash !== item.approved_content_hash) {\n  throw new Error(`Hash mismatch — refusing to publish. expected=${item.approved_content_hash} computed=${computedHash}`);\n}\n\nreturn [{json: {...item, hash_verified: true}}];"
      },
      "id": "pd0000a4-0001-0000-0000-000000000004",
      "name": "Verify Hash",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [860, 300]
    },
    {
      "parameters": {
        "rules": {
          "values": [
            {"conditions": {"options": {"caseSensitive": true, "leftValue": "", "typeValidation": "strict"}, "conditions": [{"id": "r1", "leftValue": "={{ $json.publish_mode }}", "rightValue": "postiz_scheduled", "operator": {"type": "string", "operation": "equals"}}], "combinator": "and"}, "renameOutput": true, "outputKey": "postiz"},
            {"conditions": {"options": {"caseSensitive": true, "leftValue": "", "typeValidation": "strict"}, "conditions": [{"id": "r2", "leftValue": "={{ $json.publish_mode }}", "rightValue": "postiz_immediate", "operator": {"type": "string", "operation": "equals"}}], "combinator": "and"}, "renameOutput": true, "outputKey": "postiz"},
            {"conditions": {"options": {"caseSensitive": true, "leftValue": "", "typeValidation": "strict"}, "conditions": [{"id": "r3", "leftValue": "={{ $json.publish_mode }}", "rightValue": "manual_required", "operator": {"type": "string", "operation": "equals"}}], "combinator": "and"}, "renameOutput": true, "outputKey": "manual"}
          ]
        },
        "options": {}
      },
      "id": "pd0000a5-0001-0000-0000-000000000005",
      "name": "Route by publish_mode",
      "type": "n8n-nodes-base.switch",
      "typeVersion": 3,
      "position": [1080, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "={{ $env.POSTIZ_API_BASE_URL }}/posts",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "httpHeaderAuth",
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ type: $json.publish_mode === 'postiz_immediate' ? 'now' : 'schedule', integration: { id: $json.destination_account }, posts: [{ value: [{ content: $json.final_text }] }] }) }}",
        "options": {}
      },
      "id": "pd0000a6-0001-0000-0000-000000000006",
      "name": "Postiz Create Post",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [1300, 200],
      "credentials": {
        "httpHeaderAuth": {"id": "<POSTIZ_CRED_ID>", "name": "postiz-api-key"}
      },
      "onError": "continueErrorOutput"
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "UPDATE publish_jobs SET status='sent_to_postiz', postiz_post_id=$1, sent_at=now() WHERE id=$2 RETURNING id, status;",
        "options": {"queryReplacement": "={{ [$json.id || $json.postId || $json.post_id || '', $('Verify Hash').item.json.publish_job_id] }}"}
      },
      "id": "pd0000a7-0001-0000-0000-000000000007",
      "name": "Mark Sent",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.6,
      "position": [1520, 100],
      "credentials": {
        "postgres": {"id": "fOZmso5kyXr6Agdn", "name": "outreach-db-n8n"}
      }
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "UPDATE publish_jobs SET status='failed', failure_reason=$1, attempt_count=attempt_count+1 WHERE id=$2;",
        "options": {"queryReplacement": "={{ [String($json.error || JSON.stringify($json)).slice(0, 500), $('Verify Hash').item.json.publish_job_id] }}"}
      },
      "id": "pd0000a8-0001-0000-0000-000000000008",
      "name": "Mark Failed",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.6,
      "position": [1520, 300],
      "credentials": {
        "postgres": {"id": "fOZmso5kyXr6Agdn", "name": "outreach-db-n8n"}
      }
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "UPDATE publish_jobs SET status='manual_post_required' WHERE id=$1 RETURNING id, status;",
        "options": {"queryReplacement": "={{ [$('Verify Hash').item.json.publish_job_id] }}"}
      },
      "id": "pd0000a9-0001-0000-0000-000000000009",
      "name": "Mark Manual",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.6,
      "position": [1520, 500],
      "credentials": {
        "postgres": {"id": "fOZmso5kyXr6Agdn", "name": "outreach-db-n8n"}
      }
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "UPDATE outreach_items SET status='published' WHERE id=$1 AND NOT EXISTS (SELECT 1 FROM publish_jobs pj JOIN approvals a ON a.id=pj.approval_id JOIN drafts d ON d.id=a.draft_id WHERE d.outreach_item_id=$1 AND pj.status NOT IN ('sent_to_postiz','published','manual_post_required'));",
        "options": {"queryReplacement": "={{ [$('Verify Hash').item.json.outreach_item_id] }}"}
      },
      "id": "pd0000b0-0001-0000-0000-00000000000a",
      "name": "Rollup outreach_items",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.6,
      "position": [1740, 300],
      "credentials": {
        "postgres": {"id": "fOZmso5kyXr6Agdn", "name": "outreach-db-n8n"}
      }
    }
  ],
  "connections": {
    "Schedule Trigger": {"main": [[{"node": "Fetch Ready", "type": "main", "index": 0}]]},
    "Fetch Ready": {"main": [[{"node": "Split In Batches", "type": "main", "index": 0}]]},
    "Split In Batches": {"main": [[], [{"node": "Verify Hash", "type": "main", "index": 0}]]},
    "Verify Hash": {"main": [[{"node": "Route by publish_mode", "type": "main", "index": 0}]]},
    "Route by publish_mode": {"main": [[{"node": "Postiz Create Post", "type": "main", "index": 0}], [{"node": "Postiz Create Post", "type": "main", "index": 0}], [{"node": "Mark Manual", "type": "main", "index": 0}]]},
    "Postiz Create Post": {"main": [[{"node": "Mark Sent", "type": "main", "index": 0}]], "error": [[{"node": "Mark Failed", "type": "main", "index": 0}]]},
    "Mark Sent": {"main": [[{"node": "Rollup outreach_items", "type": "main", "index": 0}]]},
    "Mark Failed": {"main": [[{"node": "Rollup outreach_items", "type": "main", "index": 0}]]},
    "Mark Manual": {"main": [[{"node": "Rollup outreach_items", "type": "main", "index": 0}]]}
  },
  "settings": {"executionOrder": "v1"}
}
```

(Note: the Postiz API request body shape `{type, integration, posts}` is the documented Postiz Public API format; verify against `https://docs.postiz.com/public-api/posts/create` and adjust if the schema differs.)

- [ ] **Step 3: Push to LXC 112 and import**

```bash
scp /tmp/publish-dispatcher.json root@192.168.1.52:/tmp/
ssh root@192.168.1.52 "scp /tmp/publish-dispatcher.json root@192.168.1.80:/tmp/"
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct push 112 /tmp/publish-dispatcher.json /tmp/publish-dispatcher.json'"
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"source /root/.nvm/nvm.sh && n8n import:workflow --input=/tmp/publish-dispatcher.json\"'"
```

n8n's `import:workflow` deactivates by default. Note the imported workflow's ID from the output.

- [ ] **Step 4: Restart n8n + activate the workflow**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- systemctl restart n8n'"
sleep 10
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"source /root/.nvm/nvm.sh && n8n update:workflow --id=<WORKFLOW_ID> --active=true\"'"
```

- [ ] **Step 5: Smoke-test — wait one tick (≤2 min) and check executions**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"sqlite3 /root/.n8n/database.sqlite \\\"SELECT id, status, startedAt FROM execution_entity WHERE workflowId='\"'\"'<WORKFLOW_ID>'\"'\"' ORDER BY id DESC LIMIT 3;\\\"\"'"
```

Expected: at least one execution with `status='success'`. No `publish_jobs.status='ready'` rows yet (Workflow C extension in Task 18 will create them), so the workflow should fire but do nothing meaningful — just `Fetch Ready` returns 0 items, downstream nodes don't execute.

---

## Task 18: Extend Workflow C's submit-approval CTE to create publish_jobs

The existing `Write Approval (CTE)` node in `apps/outreach-workflows/n8n/review.json` writes the approval + status updates atomically. Phase 2 extends it to also INSERT a `publish_jobs(status='ready')` row in the same transaction.

**Files:**
- Modify: `apps/outreach-workflows/n8n/review.json` (re-exported after edits)

- [ ] **Step 1: Find the current Write Approval CTE in the workflow**

```bash
cat /home/jacorbello/repos/cortech-infra/apps/outreach-workflows/n8n/review.json | \
  python3 -c "
import json, sys
wf = json.load(sys.stdin)
if isinstance(wf, list): wf = wf[0]
for n in wf['nodes']:
    if n['name'] == 'Write Approval (CTE)':
        print(n['parameters']['query'])
"
```

Note the existing query structure.

- [ ] **Step 2: Author the new CTE in n8n UI**

Open Workflow C (`outreach-review-notify`, ID `rEv1eWoUtReAcH001`) in n8n UI. Find the `Write Approval (CTE)` node. Replace the query with this extended version (preserving all existing parameters, just adding a 5th CTE phase):

```sql
WITH ins AS (
  INSERT INTO approvals (draft_id, approved_by, decision, edited_text, approved_destination, approved_post_type, approved_content_hash, approval_notes)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
  RETURNING id, draft_id, decision, approved_destination, approved_post_type, approved_content_hash
),
upd1 AS (
  UPDATE drafts SET status = CASE
    WHEN $3::text = 'approved' THEN 'approved'
    WHEN $3::text = 'manual_only' THEN 'approved'
    WHEN $3::text = 'rejected' THEN 'rejected'
    ELSE status
  END
  WHERE id = (SELECT draft_id FROM ins)
  RETURNING 1
),
upd2 AS (
  UPDATE drafts SET status='rejected'
  WHERE outreach_item_id = $9::bigint
    AND id <> (SELECT draft_id FROM ins)
    AND status = 'needs_human_review'
    AND $3::text IN ('approved','manual_only','rejected')
  RETURNING 1
),
upd3 AS (
  UPDATE outreach_items SET status='reviewed'
  WHERE id = $9::bigint
    AND $3::text IN ('approved','manual_only','rejected')
  RETURNING 1
),
pj AS (
  -- Phase 2: create the publish job for approved/manual_only decisions
  INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash, scheduled_for, status)
  SELECT
    ins.id,
    -- destination_platform inferred from approved_destination (e.g., "bluesky" "mastodon" "reddit" "x" "linkedin")
    -- For Phase 2.0, use the literal value Jeremy types in the approval form.
    ins.approved_destination,
    -- destination_account: the Postiz integration id. Will be the Postiz integration handle for the chosen channel.
    -- For Phase 2.0, store NULL; Workflow D handles the lookup. (Future improvement: store at approval time.)
    NULL,
    -- publish_mode: manual_only decision → 'manual_required'; everything else → 'postiz_scheduled'
    CASE
      WHEN $3::text = 'manual_only' THEN 'manual_required'
      WHEN $3::text = 'approved' THEN 'postiz_scheduled'
      ELSE NULL
    END,
    ins.approved_content_hash,
    -- scheduled_for: NULL = "as soon as Workflow D fires"
    NULL,
    'ready'
  FROM ins
  WHERE $3::text IN ('approved', 'manual_only')
  RETURNING id
)
SELECT id FROM ins;
```

Update `queryReplacement` to include the 9th parameter (`outreach_item_id`):

```
={{ [
  $('Build Approval').item.json.draft_id,
  $('Build Approval').item.json.approved_by,
  $('Build Approval').item.json.decision,
  $('Build Approval').item.json.edited_text,
  $('Build Approval').item.json.approved_destination,
  $('Build Approval').item.json.approved_post_type,
  $('Build Approval').item.json.approved_content_hash,
  $('Build Approval').item.json.approval_notes,
  $('Build Approval').item.json.outreach_item_id
] }}
```

(The outreach_item_id was already in the query as `$9` for the previous upd2/upd3 statements; the count is unchanged.)

Save the workflow in n8n UI. The workflow stays active (Postgres node parameter change doesn't deactivate).

- [ ] **Step 3: Smoke-test — approve a real draft and confirm a publish_jobs row lands**

Find a fresh outreach_item with three `needs_human_review` drafts:

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
ITEM_ID=$(psql "$ADMIN_URL" -tAc "SELECT outreach_item_id FROM drafts WHERE status='needs_human_review' GROUP BY outreach_item_id HAVING COUNT(*)=3 LIMIT 1;")
echo "Using item $ITEM_ID"
```

If none, reset one:

```bash
psql "$ADMIN_URL" -c "UPDATE drafts SET status='needs_human_review' WHERE outreach_item_id=<some_id>;"
```

Approve via the form (visit `https://n8n.corbello.io/webhook/render-approval-form?outreach_item_id=$ITEM_ID`, fill in destination `bluesky`, submit `approved`).

Verify in DB:

```bash
psql "$ADMIN_URL" -c "
SELECT pj.id, pj.approval_id, pj.destination_platform, pj.publish_mode, pj.status, pj.created_at
FROM publish_jobs pj
JOIN approvals a ON a.id = pj.approval_id
JOIN drafts d ON d.id = a.draft_id
WHERE d.outreach_item_id = $ITEM_ID
ORDER BY pj.id DESC LIMIT 5;"
```

Expected: 1 row with `publish_mode='postiz_scheduled'`, `status='ready'`, `payload_hash` populated.

- [ ] **Step 4: Export and commit**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"source /root/.nvm/nvm.sh && n8n export:workflow --id=rEv1eWoUtReAcH001 --output=/tmp/review.json\"'"
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct pull 112 /tmp/review.json /tmp/review.json && scp /tmp/review.json root@192.168.1.52:/tmp/'"
scp root@192.168.1.52:/tmp/review.json /home/jacorbello/repos/cortech-infra/apps/outreach-workflows/n8n/review.json

cd /home/jacorbello/repos/cortech-infra
python3 scripts/n8n/audit_credentials.py apps/outreach-workflows/
git add apps/outreach-workflows/n8n/review.json
git commit -m "feat(outreach-workflows): extend Workflow C CTE to create publish_jobs"
```

---

## Task 19: Export Workflow D and run audit

**Files:**
- Create: `apps/outreach-workflows/n8n/publish-dispatcher.json` (exported)

- [ ] **Step 1: Export the workflow**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"source /root/.nvm/nvm.sh && n8n export:workflow --id=<WORKFLOW_ID> --output=/tmp/publish-dispatcher.json\"'"
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct pull 112 /tmp/publish-dispatcher.json /tmp/publish-dispatcher.json && scp /tmp/publish-dispatcher.json root@192.168.1.52:/tmp/'"
scp root@192.168.1.52:/tmp/publish-dispatcher.json /home/jacorbello/repos/cortech-infra/apps/outreach-workflows/n8n/publish-dispatcher.json
```

- [ ] **Step 2: Run audit**

```bash
cd /home/jacorbello/repos/cortech-infra
python3 scripts/n8n/audit_credentials.py apps/outreach-workflows/
```

Expected: `Audit passed: no credential violations.` exit 0.

If audit fails: it usually means the workflow JSON references a credential by name that isn't in `publish-dispatcher.allow`. Fix the workflow OR the matrix.

- [ ] **Step 3: Commit**

```bash
git add apps/outreach-workflows/n8n/publish-dispatcher.json
git commit -m "feat(outreach-workflows): add Workflow D (publish-dispatcher)"
```

---

## Task 20: Workflow D — failing test for hash-recompute branch

**Files:**
- Create: `apps/outreach-workflows/tests/workflow-d/test_hash_recompute.sh`

- [ ] **Step 1: Write the test script**

`apps/outreach-workflows/tests/workflow-d/test_hash_recompute.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

echo "Setup: insert a synthetic publish_jobs row with intentionally-mismatched payload_hash"
# Find any approval to attach to (use a known one).
APPROVAL_ID=$(psql "$ADMIN_URL" -tAc "SELECT id FROM approvals WHERE decision='approved' ORDER BY id DESC LIMIT 1;")
if [ -z "$APPROVAL_ID" ]; then
  echo "FAIL: no approved approval to attach to"
  exit 1
fi

# The trigger will reject our INSERT because payload_hash won't match. So we have to bypass the trigger
# briefly by disabling it for the INSERT alone (won't roll back schema changes; we restore at end).
psql "$ADMIN_URL" <<SQL
BEGIN;
ALTER TABLE publish_jobs DISABLE TRIGGER trg_enforce_approval_match;
INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash, status)
VALUES ($APPROVAL_ID, 'bluesky', 'test-handle', 'postiz_scheduled', 'definitely_wrong_hash_xyz', 'ready')
RETURNING id;
ALTER TABLE publish_jobs ENABLE TRIGGER trg_enforce_approval_match;
COMMIT;
SQL

PUBLISH_JOB_ID=$(psql "$ADMIN_URL" -tAc "SELECT id FROM publish_jobs WHERE payload_hash='definitely_wrong_hash_xyz' LIMIT 1;")

echo "Wait 2.5 min for Workflow D to pick it up..."
sleep 150

echo "Verify: the row is NOT marked sent_to_postiz; was marked failed; attempt_count incremented"
RESULT=$(psql "$ADMIN_URL" -tAc "SELECT status, attempt_count FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
echo "Got: $RESULT"
if [[ "$RESULT" != *"failed"* ]]; then
  echo "FAIL: expected status='failed', got '$RESULT'"
  exit 1
fi
echo "PASS: Workflow D rejected mismatched hash"

echo "Cleanup: delete synthetic row"
psql "$ADMIN_URL" -c "DELETE FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;"

echo "All tests PASS"
```

```bash
chmod +x apps/outreach-workflows/tests/workflow-d/test_hash_recompute.sh
mkdir -p apps/outreach-workflows/tests/workflow-d
```

- [ ] **Step 2: Run the test**

```bash
./apps/outreach-workflows/tests/workflow-d/test_hash_recompute.sh
```

Expected: PASS — Workflow D refuses to publish, marks `failed`.

- [ ] **Step 3: Commit**

```bash
git add apps/outreach-workflows/tests/workflow-d/test_hash_recompute.sh
git commit -m "test(workflow-d): add hash-recompute defense-in-depth test"
```

---

## Task 21: Workflow D — retry-cap test + manual-required branch test

**Files:**
- Create: `apps/outreach-workflows/tests/workflow-d/test_retry_cap.sh`
- Create: `apps/outreach-workflows/tests/workflow-d/test_manual_required_branch.sh`

- [ ] **Step 1: Write the retry-cap test**

`apps/outreach-workflows/tests/workflow-d/test_retry_cap.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

# Find an approved approval to attach to.
APPROVAL_ID=$(psql "$ADMIN_URL" -tAc "SELECT id FROM approvals WHERE decision='approved' ORDER BY id DESC LIMIT 1;")
[ -z "$APPROVAL_ID" ] && { echo "FAIL: no approved approval"; exit 1; }
HASH=$(psql "$ADMIN_URL" -tAc "SELECT approved_content_hash FROM approvals WHERE id=$APPROVAL_ID;")

# Insert a row with attempt_count=3 — should NOT be picked up
psql "$ADMIN_URL" <<SQL
BEGIN;
ALTER TABLE publish_jobs DISABLE TRIGGER trg_enforce_approval_match;
INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash, status, attempt_count)
VALUES ($APPROVAL_ID, 'bluesky', 'test-cap', 'postiz_scheduled', '$HASH', 'ready', 3)
RETURNING id;
ALTER TABLE publish_jobs ENABLE TRIGGER trg_enforce_approval_match;
COMMIT;
SQL

PUBLISH_JOB_ID=$(psql "$ADMIN_URL" -tAc "SELECT id FROM publish_jobs WHERE destination_account='test-cap' AND attempt_count=3 ORDER BY id DESC LIMIT 1;")

echo "Wait 3 min — Workflow D should NOT pick this up..."
sleep 180

# Verify status is still 'ready' (untouched)
STATUS=$(psql "$ADMIN_URL" -tAc "SELECT status FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
if [ "$STATUS" != "ready" ]; then
  echo "FAIL: Workflow D should not have touched attempt_count=3 row; status=$STATUS"
  exit 1
fi
echo "PASS: retry cap honored"

# Cleanup
psql "$ADMIN_URL" -c "DELETE FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;"
echo "All tests PASS"
```

```bash
chmod +x apps/outreach-workflows/tests/workflow-d/test_retry_cap.sh
```

- [ ] **Step 2: Write the manual-required branch test**

`apps/outreach-workflows/tests/workflow-d/test_manual_required_branch.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

APPROVAL_ID=$(psql "$ADMIN_URL" -tAc "SELECT id FROM approvals WHERE decision='approved' ORDER BY id DESC LIMIT 1;")
HASH=$(psql "$ADMIN_URL" -tAc "SELECT approved_content_hash FROM approvals WHERE id=$APPROVAL_ID;")

# Insert a manual_required row
psql "$ADMIN_URL" <<SQL
BEGIN;
ALTER TABLE publish_jobs DISABLE TRIGGER trg_enforce_approval_match;
INSERT INTO publish_jobs (approval_id, destination_platform, destination_account, publish_mode, payload_hash, status)
VALUES ($APPROVAL_ID, 'reddit', 'r-other-subreddit', 'manual_required', '$HASH', 'ready')
RETURNING id;
ALTER TABLE publish_jobs ENABLE TRIGGER trg_enforce_approval_match;
COMMIT;
SQL

PUBLISH_JOB_ID=$(psql "$ADMIN_URL" -tAc "SELECT id FROM publish_jobs WHERE destination_account='r-other-subreddit' ORDER BY id DESC LIMIT 1;")

echo "Wait 2.5 min..."
sleep 150

# Expected: status='manual_post_required'
STATUS=$(psql "$ADMIN_URL" -tAc "SELECT status FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;")
if [ "$STATUS" != "manual_post_required" ]; then
  echo "FAIL: expected manual_post_required, got $STATUS"
  exit 1
fi
echo "PASS: manual_required routed to status=manual_post_required (no Postiz call)"

# Cleanup
psql "$ADMIN_URL" -c "DELETE FROM publish_jobs WHERE id=$PUBLISH_JOB_ID;"
echo "All tests PASS"
```

```bash
chmod +x apps/outreach-workflows/tests/workflow-d/test_manual_required_branch.sh
```

- [ ] **Step 3: Run both tests**

```bash
./apps/outreach-workflows/tests/workflow-d/test_retry_cap.sh
./apps/outreach-workflows/tests/workflow-d/test_manual_required_branch.sh
```

Both expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/outreach-workflows/tests/workflow-d/test_retry_cap.sh \
        apps/outreach-workflows/tests/workflow-d/test_manual_required_branch.sh
git commit -m "test(workflow-d): add retry-cap and manual_required branch tests"
```

---

## Task 22: Channel onboarding — Bluesky

**Files:** (none — operational; channel registered in Postiz DB)

- [ ] **Step 1: Create Bluesky account**

Visit https://bsky.app. Sign up:
- Handle: `plotlens.bsky.social` (or your preferred handle)
- Email: `jacorbello@gmail.com`
- Password: save to your password manager

Verify the email link Bluesky sends.

- [ ] **Step 2: Create an App Password**

Bluesky UI → Settings → App Passwords → Add App Password.
- Name: `postiz`
- Click "Create"
- Copy the password (one-time view; format is `xxxx-xxxx-xxxx-xxxx`).

- [ ] **Step 3: Connect Postiz to Bluesky**

Postiz UI (`https://postiz.corbello.io`) → Integrations → Add Channel → Bluesky.
- Handle: `plotlens.bsky.social`
- App password: (paste from Step 2)
- Click "Connect"

Confirm the new Bluesky integration appears under "Connected Channels".

- [ ] **Step 4: Smoke post**

In Postiz UI → New Post → select the Bluesky integration → Content: `Testing PlotLens outreach pipeline (Phase 2 smoke).` → click "Post Now".

Check your Bluesky profile at `https://bsky.app/profile/plotlens.bsky.social` — the post should be visible within seconds.

- [ ] **Step 5: Retrieve the Postiz integration ID**

```bash
TOKEN=$(infisical secrets get POSTIZ_API_KEY --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)
curl -sS -H "Authorization: Bearer $TOKEN" "https://postiz.corbello.io/api/integrations" | python3 -m json.tool
```

Note the Bluesky integration's `id` field. Save it as `POSTIZ_INTEGRATION_BLUESKY` in Infisical (under `/postiz`).

```bash
infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  "POSTIZ_INTEGRATION_BLUESKY=<integration_id_from_response>"
```

This becomes the value Jeremy will enter as `approved_destination` when approving drafts targeted at Bluesky.

---

## Task 23: Channel onboarding — Mastodon

**Files:** (none — operational)

- [ ] **Step 1: Pick a Mastodon instance**

Recommended: `mastodon.social` (largest, most likely to be reachable from any Postiz webhook). Alternative: `wandering.shop` (writer-focused).

This plan uses `mastodon.social`.

- [ ] **Step 2: Create the account**

Visit `https://mastodon.social/auth/sign_up`.
- Username: `plotlens`
- Email: `jacorbello@gmail.com`
- Password: save to password manager

Verify the confirmation email.

- [ ] **Step 3: Create an application token**

Mastodon UI → Preferences → Development → New Application.
- Application name: `postiz`
- Scopes: leave `read write` checked; uncheck `follow` and `push` (not needed for outbound posting)
- Click "Submit"
- Click the application name to reveal "Your access token" — copy it.

- [ ] **Step 4: Connect Postiz to Mastodon**

Postiz UI → Integrations → Add Channel → Mastodon.
- Instance URL: `https://mastodon.social`
- Access token: (paste from Step 3)
- Click "Connect"

- [ ] **Step 5: Smoke post**

Postiz UI → New Post → Mastodon integration → Content: `PlotLens outreach Phase 2 smoke from Mastodon.` → Post Now.

Visit `https://mastodon.social/@plotlens` — post should be visible.

- [ ] **Step 6: Save integration ID**

```bash
TOKEN=$(infisical secrets get POSTIZ_API_KEY --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)
curl -sS -H "Authorization: Bearer $TOKEN" "https://postiz.corbello.io/api/integrations" | python3 -m json.tool | grep -A2 mastodon
```

Save the Mastodon integration's `id` to Infisical:

```bash
infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  "POSTIZ_INTEGRATION_MASTODON=<integration_id>"
```

---

## Task 24: Channel onboarding — r/PlotLens (Reddit)

**Files:** (none — operational)

- [ ] **Step 1: Confirm moderator access to r/PlotLens**

Visit `https://www.reddit.com/r/PlotLens/about/moderators/`. Confirm your moderator account is listed.

If you're not modding under the account that will OAuth into Postiz, add that account as a moderator first (Mod Tools → Moderators → Invite User; the invited user must accept).

- [ ] **Step 2: Create a Reddit OAuth app**

Visit `https://www.reddit.com/prefs/apps`. Scroll to bottom → "Create another app".
- Name: `postiz`
- Type: **web app**
- Description: `Self-hosted social scheduler for PlotLens`
- About URL: `https://postiz.corbello.io`
- Redirect URI: This must match Postiz's callback. Check Postiz docs for the exact format — typically `https://postiz.corbello.io/integrations/social/reddit`. If unsure, start the Reddit integration in Postiz UI and observe the redirect URL it asks for; copy that.
- Click "Create app"

Copy:
- Client ID (shown immediately below the app name, top-left)
- Client Secret (shown next to "secret:")

- [ ] **Step 3: Connect Postiz to Reddit**

Postiz UI → Integrations → Add Channel → Reddit.
- Client ID: (paste from Step 2)
- Client Secret: (paste from Step 2)
- Click "Connect"

OAuth flow opens. Sign in to Reddit, click "Allow" to grant Postiz access.

After redirect, the Reddit integration should appear in Postiz. It may ask you to select the subreddit — choose `PlotLens`.

- [ ] **Step 4: Smoke post**

Postiz UI → New Post → Reddit integration.
- Subreddit: `PlotLens`
- Title: `Phase 2 outreach pipeline test post`
- Content: `Testing PlotLens outreach automation. This message was posted via the publish dispatcher; you can ignore it.`
- Post type: `self` (text post)
- Click "Post Now"

Visit `https://reddit.com/r/PlotLens` — post should be visible.

- [ ] **Step 5: Save integration ID**

```bash
TOKEN=$(infisical secrets get POSTIZ_API_KEY --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)
curl -sS -H "Authorization: Bearer $TOKEN" "https://postiz.corbello.io/api/integrations" | python3 -m json.tool | grep -A2 reddit

infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  "POSTIZ_INTEGRATION_REDDIT_PLOTLENS=<integration_id>"
```

---

## Task 25: End-to-end test — discover → draft → approve → Postiz publish

**Files:** (none — verification only)

- [ ] **Step 1: Trigger Discover with a real URL**

```bash
SECRET=$(infisical secrets get DISCOVER_WEBHOOK_SECRET --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)

curl -sS -X POST -H "X-Discover-Secret: $SECRET" -H "Content-Type: application/json" \
  -d '{"url": "https://plotlens.ai/blog/phase-2-launch-test", "notes": "phase 2 e2e test"}' \
  https://n8n.corbello.io/webhook/outreach-discover
```

Expected response: `{"accepted":true,"id":<new_outreach_item_id>}`.

- [ ] **Step 2: Wait for Draft workflow (~5 min)**

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
psql "$ADMIN_URL" -c "
SELECT oi.id, oi.status, COUNT(d.id) AS draft_count
FROM outreach_items oi LEFT JOIN drafts d ON d.outreach_item_id=oi.id
WHERE oi.source_url='https://plotlens.ai/blog/phase-2-launch-test'
GROUP BY oi.id, oi.status;"
```

Expected within 5-7 min: `status='drafted'`, `draft_count=3`.

- [ ] **Step 3: Approve via the review form (Bluesky destination)**

Visit `https://n8n.corbello.io/webhook/render-approval-form?outreach_item_id=<NEW_ID>` in browser (Basic Auth with `N8N_FORM_AUTH_USER`/`N8N_FORM_AUTH_PASSWORD`).

In the form:
- Approved destination: `<POSTIZ_INTEGRATION_BLUESKY value from Task 22>`
- Approved post type: `post`
- Notes: `phase 2 e2e`
- Click "Approve chosen variant" with the helpful_only variant selected.

- [ ] **Step 4: Verify publish_jobs row was created**

```bash
psql "$ADMIN_URL" -c "
SELECT pj.id, pj.publish_mode, pj.destination_platform, pj.status, pj.attempt_count, pj.created_at
FROM publish_jobs pj
JOIN approvals a ON a.id = pj.approval_id
JOIN drafts d ON d.id = a.draft_id
WHERE d.outreach_item_id = <NEW_ID>
ORDER BY pj.id DESC LIMIT 5;"
```

Expected: 1 row with `publish_mode='postiz_scheduled'`, `status='ready'`.

- [ ] **Step 5: Wait 2-3 min, verify Workflow D processed it**

```bash
psql "$ADMIN_URL" -c "
SELECT pj.id, pj.status, pj.postiz_post_id, pj.sent_at, pj.failure_reason
FROM publish_jobs pj
JOIN approvals a ON a.id = pj.approval_id
JOIN drafts d ON d.id = a.draft_id
WHERE d.outreach_item_id = <NEW_ID>
ORDER BY pj.id DESC LIMIT 5;"
```

Expected: `status='sent_to_postiz'`, `postiz_post_id` populated, `sent_at` non-null.

- [ ] **Step 6: Verify the post is on Bluesky**

Visit your Bluesky profile. The approved draft text should be visible.

If `status='failed'` instead: read `failure_reason`. Common causes:
- Wrong Postiz API request shape (check `apps/outreach-workflows/n8n/publish-dispatcher.json` against Postiz docs).
- Postiz integration ID typo in approval.

- [ ] **Step 7: Verify outreach_items rollup**

```bash
psql "$ADMIN_URL" -c "SELECT id, status FROM outreach_items WHERE id=<NEW_ID>;"
```

Expected: `status='published'`.

If the rollup didn't fire, the `Rollup outreach_items` node in Workflow D is the place to debug.

---

## Task 26: Grafana dashboard for plotlens-marketing

**Files:**
- Create: `k8s/observability/dashboards/applications/plotlens-marketing.json`

- [ ] **Step 1: Author the dashboard JSON**

Find an existing dashboard as a template:

```bash
ls k8s/observability/dashboards/applications/
```

Copy a small one (e.g., `_template.yaml` if present, or any existing app dashboard) as a reference.

Create `k8s/observability/dashboards/applications/plotlens-marketing.json` as a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: plotlens-marketing-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  plotlens-marketing.json: |
    {
      "title": "PlotLens Marketing — Outreach Pipeline",
      "uid": "plotlens-marketing",
      "tags": ["plotlens","outreach"],
      "timezone": "browser",
      "schemaVersion": 38,
      "refresh": "30s",
      "time": {"from": "now-24h", "to": "now"},
      "panels": [
        {
          "id": 1,
          "title": "publish_jobs by status",
          "type": "stat",
          "gridPos": {"h": 4, "w": 24, "x": 0, "y": 0},
          "targets": [
            {"datasource": {"type": "postgres", "uid": "outreach-pg"}, "rawQuery": true, "rawSql": "SELECT status, COUNT(*) AS count FROM publish_jobs WHERE created_at > now() - interval '24h' GROUP BY status;", "format": "table"}
          ]
        },
        {
          "id": 2,
          "title": "Workflow D execution duration (p95)",
          "type": "graph",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
          "targets": [
            {"expr": "histogram_quantile(0.95, sum(rate(n8n_workflow_execution_duration_seconds_bucket{workflow=\"outreach-publish-dispatcher\"}[5m])) by (le))"}
          ]
        },
        {
          "id": 3,
          "title": "enforce_approval_match trigger rejections (MUST be 0)",
          "type": "stat",
          "gridPos": {"h": 4, "w": 12, "x": 12, "y": 4},
          "targets": [
            {"datasource": {"type": "loki", "uid": "loki"}, "expr": "{namespace=\"outreach\"} |~ \"enforce_approval_match.*RAISE\""}
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": 0}, {"color": "red", "value": 1}]}
            }
          }
        },
        {
          "id": 4,
          "title": "Postiz API call success rate",
          "type": "graph",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12},
          "targets": [
            {"datasource": {"type": "postgres", "uid": "outreach-pg"}, "rawQuery": true, "rawSql": "SELECT date_trunc('hour', sent_at) AS time, COUNT(*) FILTER (WHERE status='sent_to_postiz')::float / NULLIF(COUNT(*),0) AS success_rate FROM publish_jobs WHERE sent_at > now() - interval '24h' GROUP BY 1 ORDER BY 1;"}
          ]
        },
        {
          "id": 5,
          "title": "outreach_items status",
          "type": "piechart",
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 12},
          "targets": [
            {"datasource": {"type": "postgres", "uid": "outreach-pg"}, "rawQuery": true, "rawSql": "SELECT status, COUNT(*) FROM outreach_items WHERE discovered_at > now() - interval '7d' GROUP BY status;"}
          ]
        }
      ]
    }
```

(Adapt panel queries to your Grafana datasource UIDs — check what's already in use by other dashboards.)

- [ ] **Step 2: Apply via kubectl (or let ArgoCD pick it up if `k8s/observability/` is in an Application)**

```bash
ssh root@192.168.1.52 "kubectl apply -f /home/jacorbello/repos/cortech-infra/k8s/observability/dashboards/applications/plotlens-marketing.json -n observability"
```

(If `k8s/observability/` is GitOps-managed, just commit and push — the sidecar will reload.)

- [ ] **Step 3: Verify in Grafana**

Visit `https://grafana.corbello.io` → Dashboards → search "PlotLens Marketing".

- [ ] **Step 4: Commit**

```bash
git add k8s/observability/dashboards/applications/plotlens-marketing.json
git commit -m "feat(observability): add plotlens-marketing dashboard"
```

---

## Task 27: Alertmanager rules

**Files:**
- Modify: existing PrometheusRule manifest (find via `grep -r "PrometheusRule" k8s/`)

- [ ] **Step 1: Find the existing PrometheusRule for outreach (Phase 1) or kube-prometheus**

```bash
grep -r "PrometheusRule\|enforce_approval_match" k8s/ /home/jacorbello/repos/cortech-infra/apps/outreach-workflows/ 2>/dev/null | head -10
```

If Phase 1 added a PrometheusRule, edit it. Otherwise create a new one:

- [ ] **Step 2: Author the rule**

Create `k8s/observability/alerts/plotlens-marketing-rules.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: plotlens-marketing-alerts
  namespace: observability
  labels:
    release: prometheus
spec:
  groups:
    - name: plotlens-marketing
      interval: 30s
      rules:
        - alert: OutreachPublishJobStalled
          expr: |
            min_over_time(
              postgres_publish_jobs_ready_count[15m]
            ) > 0
            AND
            postgres_publish_jobs_ready_oldest_age_minutes > 15
          for: 1m
          labels:
            severity: page
          annotations:
            summary: "publish_jobs in 'ready' state for >15 minutes — Workflow D stalled"
            description: "{{ $value }} publish_jobs rows have been 'ready' for >15 min. Investigate n8n Workflow D execution log."

        - alert: OutreachPublishFailureSustained
          expr: |
            sum(rate(postgres_publish_jobs_failed_total[5m])) > 0
          for: 5m
          labels:
            severity: warn
          annotations:
            summary: "publish_jobs failures sustained for >5 min"
            description: "Check Postiz API health and Workflow D error branch."

        - alert: PostizPodCrashLooping
          expr: |
            increase(kube_pod_container_status_restarts_total{namespace="plotlens-marketing",pod=~"postiz-.*"}[10m]) > 1
          for: 1m
          labels:
            severity: warn
          annotations:
            summary: "Postiz pod restarting in plotlens-marketing"

        - alert: TemporalPodCrashLooping
          expr: |
            increase(kube_pod_container_status_restarts_total{namespace="plotlens-marketing",pod=~"temporal-.*"}[10m]) > 1
          for: 1m
          labels:
            severity: warn
          annotations:
            summary: "Temporal pod restarting in plotlens-marketing"
```

(The `postgres_publish_jobs_*` metrics assume a postgres_exporter custom query is configured. If not, replace with a simpler PromQL based on what's actually scraped, or skip the publish-jobs alerts and rely on the Grafana dashboard's red threshold for visibility.)

- [ ] **Step 3: Apply**

```bash
ssh root@192.168.1.52 "kubectl apply -f /home/jacorbello/repos/cortech-infra/k8s/observability/alerts/plotlens-marketing-rules.yaml"
```

- [ ] **Step 4: Verify in Prometheus UI**

Visit `https://prometheus.corbello.io/alerts` (or wherever Prometheus is exposed). The 4 new rules should appear under `plotlens-marketing` group.

- [ ] **Step 5: Commit**

```bash
git add k8s/observability/alerts/plotlens-marketing-rules.yaml
git commit -m "feat(observability): add plotlens-marketing alerting rules"
```

---

## Task 28: Operational runbooks

**Files:**
- Create: `docs/runbooks/postiz-channel-onboarding.md`
- Create: `docs/runbooks/postiz-failed-job-recovery.md`
- Create: `docs/runbooks/temporal-restart.md`

- [ ] **Step 1: Channel onboarding runbook**

`docs/runbooks/postiz-channel-onboarding.md`:

```markdown
# Adding a New Channel to Postiz

This runbook covers connecting a new social channel to the PlotLens outreach pipeline. See `docs/superpowers/plans/2026-05-20-plotlens-outreach-phase2.md` Tasks 22-24 for the initial onboarding of Bluesky, Mastodon, and r/PlotLens.

## Pre-flight

1. The Postiz integration for the channel must exist as a provider in the running Postiz version. Check Postiz docs (`https://docs.postiz.com/providers/overview`).
2. Phase 2's three channels (Bluesky, Mastodon, r/PlotLens) are reference cases.

## Steps (in order)

### 1. Create the social account if it doesn't exist

Use the brand convention: `@plotlens` / `plotlens.<instance>` / similar.

### 2. Register OAuth app or generate an access token

Platform-specific. Check Postiz's provider docs for the exact requirements (e.g., X needs OAuth2 + OAuth1; Bluesky needs an app password).

### 3. Connect via Postiz UI

`https://postiz.corbello.io` → Integrations → Add Channel → pick provider → enter credentials.

### 4. Smoke post

Test with a one-line message. Confirm visibility on the platform.

### 5. Save integration ID to Infisical

```bash
TOKEN=$(infisical secrets get POSTIZ_API_KEY --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)
curl -sS -H "Authorization: Bearer $TOKEN" "https://postiz.corbello.io/api/integrations" | python3 -m json.tool

infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  "POSTIZ_INTEGRATION_<CHANNEL_NAME>=<integration_id>"
```

### 6. Update Workflow D if the channel needs platform-specific request shape

Some channels (Reddit subreddit posts, X with media) need additional fields in the Postiz Create Post body. Edit the `Postiz Create Post` node's `jsonBody` expression in n8n; export workflow and commit.

### 7. Use it in approvals

When approving a draft, enter the `POSTIZ_INTEGRATION_<CHANNEL>` value in the "Approved destination" field. Workflow D picks it up.

## Per-channel quirks

### Reddit
- Comment replies = manual-only (any subreddit, including r/PlotLens). Workflow D's Switch enforces `publish_mode='manual_required'` for `destination_post_type='comment'`.
- Original posts to r/PlotLens via Postiz = allowed.
- API rate limits: Postiz handles backoff; high-volume bursts may queue.

### X
- Free tier hard limit: 1500 posts/month.
- The `made_with_ai` flag (in Postiz's X settings) defaults to `false` since all posts are human-approved.

### LinkedIn
- Marketing Developer Platform approval can take 1-2 weeks.
- Fallback if denied: use "Share on LinkedIn" only (posts as personal profile, not Company Page).
```

- [ ] **Step 2: Failed-job recovery runbook**

`docs/runbooks/postiz-failed-job-recovery.md`:

```markdown
# Recovering Failed publish_jobs

A `publish_jobs.status='failed'` row means Workflow D's Postiz Create Post call returned non-2xx or threw. After `attempt_count` reaches 3, the row stays `failed` and is never retried automatically.

## Identify the failures

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
psql "$ADMIN_URL" -c "
SELECT pj.id, pj.destination_platform, pj.destination_account, pj.attempt_count, pj.failure_reason, pj.created_at
FROM publish_jobs pj
WHERE pj.status='failed'
ORDER BY pj.created_at DESC LIMIT 20;"
```

Read `failure_reason` to understand the error.

## Common causes and fixes

| failure_reason contains | Likely cause | Fix |
|---|---|---|
| `401 Unauthorized` | Postiz API key revoked or wrong | Regenerate in Postiz UI; update Infisical `POSTIZ_API_KEY` |
| `429 Too Many Requests` | Platform rate limit (X free tier 1500/mo) | Wait; consider raising X tier |
| `Integration not found` | Wrong integration ID in `destination_account` | Look up correct ID via `GET /api/integrations`; update the approval and re-queue |
| `Hash mismatch` | Workflow D's defense-in-depth fired | Means the approved text was edited in DB. Re-approve via the form. |
| Network timeout | Postiz pod down or LXC 100 NGINX unreachable | Check `kubectl get pods -n plotlens-marketing`; check LXC 100 NGINX |

## Re-queue a failed job

If the root cause is fixed (e.g., new API key), reset the row to `ready` with `attempt_count=0`:

```bash
psql "$ADMIN_URL" -c "
UPDATE publish_jobs
SET status='ready', attempt_count=0, failure_reason=NULL
WHERE id=<PUBLISH_JOB_ID>;"
```

Workflow D will pick it up within 2 minutes.

## Permanently abandon a job

If a publish should never run (e.g., wrong destination at approval time, no longer relevant):

```bash
psql "$ADMIN_URL" -c "
UPDATE publish_jobs
SET status='abandoned', failure_reason=COALESCE(failure_reason,'') || ' [manually abandoned at ' || now()::text || ']'
WHERE id=<PUBLISH_JOB_ID>;"
```

(If the `status` CHECK constraint doesn't include `'abandoned'`, add it via a migration first.)

## When the failure is in the approval itself

If the underlying approval was a mistake (wrong text, wrong destination), see `docs/runbooks/revoke-approval.md`. Revoke the approval, then DELETE the failed publish_jobs row.
```

- [ ] **Step 3: Temporal restart runbook**

`docs/runbooks/temporal-restart.md`:

```markdown
# Temporal Restart

Temporal is deployed in `plotlens-marketing` via ArgoCD. Postiz uses it for scheduled-post / background-workflow execution.

## When to restart

- Temporal Web UI unreachable.
- Postiz logs show "Temporal connection failed".
- Alertmanager fires `TemporalPodCrashLooping`.
- After a chart values change in `apps/temporal/values.yaml`.

## Restart procedure

### Soft restart (rolling)

```bash
ssh root@192.168.1.52 "kubectl rollout restart deployment -n plotlens-marketing -l app.kubernetes.io/name=temporal"
ssh root@192.168.1.52 "kubectl rollout status deployment -n plotlens-marketing -l app.kubernetes.io/name=temporal --timeout=180s"
```

### Hard restart (delete pods)

```bash
ssh root@192.168.1.52 "kubectl delete pod -n plotlens-marketing -l app.kubernetes.io/name=temporal"
```

ArgoCD will recreate them on the next reconciliation (~30 sec).

### Full re-sync via ArgoCD

If a values change isn't taking effect:

```bash
# Force a refresh + sync
ssh root@192.168.1.52 "kubectl patch application temporal -n argocd --type merge -p '{\"operation\":{\"sync\":{}}}'"
```

## Verification after restart

1. All temporal-* pods Running:
   ```bash
   ssh root@192.168.1.52 "kubectl get pods -n plotlens-marketing | grep temporal"
   ```
2. Temporal UI reachable:
   ```bash
   curl -sI https://temporal.corbello.io/ | head -3
   ```
3. Postiz log shows "Temporal connection established":
   ```bash
   ssh root@192.168.1.52 "kubectl logs -n plotlens-marketing -l app=postiz --tail=50 | grep -i temporal"
   ```
4. Run a smoke post through Postiz to confirm the worker is processing.

## What survives a restart

- All workflow state persists in the `temporal` and `temporal_visibility` Postgres DBs on LXC 114.
- Active workflows resume from their last checkpoint.
- Scheduled posts in Postiz are NOT lost (Postiz stores them in its own `postiz` DB; Temporal just re-runs the schedule).

## What does NOT survive

- In-flight HTTP requests at the moment of pod death.
- Workflow runs that were mid-execution: Temporal retries them automatically on resume.

## When the DB is the problem

If Temporal can't connect to Postgres at all:
- Check LXC 114 reachability: `psql "postgres://temporal_app:...@192.168.1.83:5432/temporal" -c "SELECT 1;"`
- Check the password in Infisical matches the role: `infisical secrets get TEMPORAL_DATABASE_PASSWORD --projectId=db72a923-... --env=dev --path=/temporal --plain`
- The `temporal-secrets` K8s Secret is synced by Infisical Operator every 60s; if stale, restart the InfisicalSecret:
  ```bash
  ssh root@192.168.1.52 "kubectl delete infisicalsecret temporal-secrets -n plotlens-marketing"
  # ArgoCD will recreate it on the next sync, or apply manually:
  ssh root@192.168.1.52 "kubectl apply -f /tmp/temporal-secrets.yaml"
  ```
```

- [ ] **Step 4: Commit**

```bash
git add docs/runbooks/postiz-channel-onboarding.md \
        docs/runbooks/postiz-failed-job-recovery.md \
        docs/runbooks/temporal-restart.md
git commit -m "docs(runbooks): add Phase 2 Postiz and Temporal runbooks"
```

---

## Task 29: Add manifests-lint job to outreach-ci.yml

**Files:**
- Modify: `.github/workflows/outreach-ci.yml`

- [ ] **Step 1: Read current CI**

```bash
cat .github/workflows/outreach-ci.yml
```

- [ ] **Step 2: Add the new job**

Edit `.github/workflows/outreach-ci.yml` — append a new job after the existing `audit` job:

```yaml
  manifests-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install kustomize
        run: |
          curl -sLo kustomize.tar.gz https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v5.4.3/kustomize_v5.4.3_linux_amd64.tar.gz
          tar -xzf kustomize.tar.gz
          sudo mv kustomize /usr/local/bin/

      - name: Build Postiz manifests
        run: kustomize build apps/postiz/overlays/production > /tmp/postiz-rendered.yaml

      - name: Install kubectl
        uses: azure/setup-kubectl@v3
        with:
          version: v1.30.0

      - name: Validate Postiz manifests
        run: kubectl apply --dry-run=client -f /tmp/postiz-rendered.yaml

      - name: Install helm
        uses: azure/setup-helm@v3
        with:
          version: v3.14.0

      - name: Lint Temporal Helm values
        run: |
          helm repo add temporalio https://go.temporal.io/helm-charts
          helm template temporal temporalio/temporal --version 0.74.0 -f apps/temporal/values.yaml > /tmp/temporal-rendered.yaml
          kubectl apply --dry-run=client -f /tmp/temporal-rendered.yaml || echo "Temporal validate failed (non-blocking for now; chart 0.74 may have CRDs)"

      - name: Validate Temporal extras
        run: kustomize build apps/temporal/extras > /tmp/temporal-extras-rendered.yaml && kubectl apply --dry-run=client -f /tmp/temporal-extras-rendered.yaml
```

- [ ] **Step 3: Commit and push to trigger CI**

```bash
git add .github/workflows/outreach-ci.yml
git commit -m "ci(outreach): add manifests-lint job for Phase 2"
git push origin outreach/phase0-phase1
```

- [ ] **Step 4: Verify CI passes**

Visit the GitHub repo → Actions tab. Confirm all three jobs (schema, audit, manifests-lint) pass.

If `manifests-lint` fails: read the error. Common issues:
- Missing `nfs-csi` storageClass on the CI's offline lint (use `--dry-run=client` which skips storageClass validation; already in the config).
- Missing CRDs (Traefik IngressRoute, InfisicalSecret, ServiceMonitor): add `--validate=false` to the kubectl commands if needed.

---

## Task 30: Phase 2 exit verification

**Files:** (none — verification)

- [ ] **Step 1: ArgoCD Applications healthy for 24h**

```bash
ssh root@192.168.1.52 "kubectl get application temporal postiz -n argocd -o jsonpath='{range .items[*]}{.metadata.name}: {.status.sync.status} {.status.health.status}{\"\\n\"}{end}'"
```

Both should show `Synced Healthy`. Check at install time, then again 24h later.

- [ ] **Step 2: Three channels verified end-to-end**

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
psql "$ADMIN_URL" -c "
SELECT pj.destination_platform, COUNT(*) AS posts_sent
FROM publish_jobs pj
WHERE pj.status='sent_to_postiz'
GROUP BY pj.destination_platform
ORDER BY pj.destination_platform;"
```

Expected: at least 1 row each for bluesky, mastodon, reddit (or whichever the integration IDs map to). At least 2 distinct platforms.

- [ ] **Step 3: 5 distinct posts published**

```bash
psql "$ADMIN_URL" -c "SELECT COUNT(*) AS total_sent FROM publish_jobs WHERE status='sent_to_postiz';"
```

Expected: ≥ 5.

- [ ] **Step 4: Synthetic trigger-bypass tests pass**

```bash
./apps/outreach-schema/db/tests/run_tests.sh
./apps/outreach-schema/db/tests/publish_jobs_attempt_count_test.sql.sh
./apps/outreach-schema/db/tests/outreach_items_published_rollup_test.sql.sh
./apps/outreach-workflows/tests/workflow-d/test_hash_recompute.sh
./apps/outreach-workflows/tests/workflow-d/test_retry_cap.sh
./apps/outreach-workflows/tests/workflow-d/test_manual_required_branch.sh
```

All expected: PASS.

- [ ] **Step 5: Trigger rejections = 0**

Check Grafana panel `enforce_approval_match trigger rejections`. Value MUST be 0. If non-zero: investigate which payload was rejected and why before proceeding. Could indicate Workflow D's hash recompute disagreeing with the approval's stored hash — a real bug.

- [ ] **Step 6: Workflow D execution success rate ≥ 99% over 48h**

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"sqlite3 /root/.n8n/database.sqlite \\\"SELECT status, COUNT(*) FROM execution_entity WHERE workflowId='\"'\"'<WORKFLOW_D_ID>'\"'\"' AND startedAt > datetime('\"'\"'now'\"'\"','\"'\"'-48 hours'\"'\"') GROUP BY status;\\\"\"'"
```

Compute success / (success + error). Expected ≥ 0.99.

- [ ] **Step 7: One full week without manual DB intervention**

Run after a full 7-day calendar week of Phase 2 in production. Verify: no manual UPDATEs to `publish_jobs.status`, no manual DELETEs, no ad-hoc trigger rule changes.

- [ ] **Step 8: Update the living roadmap**

Edit `docs/superpowers/roadmaps/plotlens-outreach.md`:
- Phase 2 status → `shipped`
- Add the Phase 2 tag once Step 9 completes.
- Move any newly-active decisions out of "Open decisions" into "Active decisions".
- Add to "Deferred items" anything that slipped (e.g., LinkedIn if approval didn't land).

```bash
git add docs/superpowers/roadmaps/plotlens-outreach.md
git commit -m "docs(roadmap): mark Phase 2 shipped"
```

- [ ] **Step 9: Tag the release**

Verify Phase 1 is tagged first (it must be tagged before Phase 2 per exit criterion 9):
```bash
git tag -l 'outreach-phase1-shipped'
```

If empty, complete Phase 1's exit verification + tag first.

Then tag Phase 2:
```bash
git tag -a outreach-phase2-shipped -m "PlotLens outreach Phase 2 shipped: Postiz + Temporal in production with Workflow D dispatcher and 3 channels live"
git push origin outreach-phase2-shipped
```

---

## Phase 2.1 follow-ups (if X / LinkedIn OAuth lagged)

If exit criterion #2 was met with only Bluesky + Mastodon + r/PlotLens, the following are Phase 2.1 work and not blocking:

### 2.1-A: X — once Developer Account approved

1. Apply for X Developer Account at `https://developer.x.com` if not already in flight.
   - Description: `Self-hosted social scheduler for a writing-tools SaaS.`
   - Free tier (1500 posts/month) is enough.
2. After approval (1-7 days), create a Project + App. Settings → User authentication settings → enable both OAuth 2.0 and OAuth 1.0a per Postiz docs.
3. Set callback URL to Postiz's X callback (check Postiz UI).
4. Generate API key + secret (OAuth 1.0a) and Client ID + Client secret (OAuth 2.0). Save all four.
5. Postiz UI → Integrations → Add Channel → X → paste all four credentials. OAuth flow opens.
6. Smoke post (text-only first, then with image).
7. Save integration ID to Infisical as `POSTIZ_INTEGRATION_X`.

### 2.1-B: LinkedIn — once Marketing Dev Platform approved

1. Create personal LinkedIn account if needed.
2. Create Company Page for PlotLens at `https://www.linkedin.com/company/setup/new/`.
3. LinkedIn Developer Portal → Create App. Associate with Company Page.
4. Apply for "Marketing Developer Platform" product (1-2 weeks).
5. While waiting: configure OAuth redirect URL + get Client ID/Secret.
6. After approval: Postiz UI → Integrations → Add Channel → LinkedIn (Page) → OAuth as page admin.
7. Smoke post (text-only).
8. Save integration ID to Infisical as `POSTIZ_INTEGRATION_LINKEDIN`.

If Marketing Dev Platform is denied: fall back to "Share on LinkedIn" only (posts as personal profile, not Company Page).

---

## Phase 2 task summary

| Task | Component | Files |
|---|---|---|
| 1 | Roadmap doc | `docs/superpowers/roadmaps/plotlens-outreach.md` |
| 2 | Pre-flight verification | none |
| 3 | LXC 114 — create postiz + temporal DBs | none (out-of-band) |
| 4 | MinIO — create postiz-media bucket + user | none (out-of-band) |
| 5 | Schema — publish_jobs.attempt_count + sent_at | 1 migration + 1 test |
| 6 | Schema — outreach_items.status += 'published' | 1 migration + 1 test |
| 7 | Infisical — store Phase 2 secrets | none (out-of-band) |
| 8 | apps/temporal/ extras + values.yaml | 6 files |
| 9 | apps/temporal/argocd-application.yaml + sync | 1 file |
| 10 | proxy/sites/temporal.corbello.io.conf | 1 file |
| 11 | apps/postiz/ base manifests | 11 files |
| 12 | apps/postiz/argocd-application.yaml + sync | 1 file |
| 13 | proxy/sites/postiz.corbello.io.conf + webhooks | 2 files |
| 14 | Postiz first-run setup + API key generation | none (out-of-band, secret to Infisical) |
| 15 | credentials-matrix.yaml — publish-dispatcher | modify |
| 16 | LXC 112 — n8n env vars for Postiz | none (out-of-band) |
| 17 | Workflow D — build + import | 1 file |
| 18 | Workflow C — extend CTE to create publish_jobs | modify |
| 19 | Workflow D — export + audit | 1 file |
| 20 | Workflow D — hash-recompute test | 1 file |
| 21 | Workflow D — retry-cap + manual-required tests | 2 files |
| 22 | Bluesky onboarding | none (out-of-band) |
| 23 | Mastodon onboarding | none (out-of-band) |
| 24 | r/PlotLens onboarding | none (out-of-band) |
| 25 | End-to-end smoke test | none (verification) |
| 26 | Grafana dashboard | 1 file |
| 27 | Alertmanager rules | 1 file |
| 28 | Runbooks (3) | 3 files |
| 29 | CI — manifests-lint job | modify |
| 30 | Phase 2 exit verification + tag | none (verification) |

30 tasks. Out-of-band tasks (Infisical, LXC, social account setup) intentionally don't produce repo files but are tracked as plan items.
