# Running the n8n Credential Audit

## What it does

`scripts/n8n/audit_credentials.py` reads `apps/outreach-workflows/credentials-matrix.yaml` and asserts every workflow JSON under `apps/outreach-workflows/n8n/` only references credentials in its allowlist.

The matrix is the single source of truth for which credentials each outreach workflow is allowed to use. A workflow that imports a forbidden credential (e.g., the draft workflow referencing the Slack bot token, or the discover workflow accessing the Anthropic API) fails the audit.

## Running locally before pushing

```bash
python scripts/n8n/audit_credentials.py apps/outreach-workflows/
```

Exit 0 = clean. Exit 1 = violations printed to stderr.

## When CI fails on this

The PR's audit job will print the violations. Either:

- **Fix the workflow JSON** — remove the disallowed credential from the n8n UI, re-export, and commit. This is the right fix when the credential leaked in by accident (e.g., copy-pasted from another workflow).
- **Update the matrix** — if the credential genuinely belongs on this workflow now, update `credentials-matrix.yaml` to allow it. Be explicit about *why* in the PR description. Tightening the allowlist later is easier than realizing months from now that a workflow is using a credential nobody intended.

## Adding a new workflow

1. Add an entry to `workflows:` in `apps/outreach-workflows/credentials-matrix.yaml` with its filename and `allow:` list.
2. Build the workflow in n8n.
3. Export to `apps/outreach-workflows/n8n/<name>.json` (see runbook `n8n-export.md` if one exists, or use the inline `ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- bash -c \"source /root/.nvm/nvm.sh && n8n export:workflow --id=<id> --output=/tmp/x.json\"'"` pattern).
4. Run the audit locally.
5. Commit the JSON + matrix update together.

## Forbidden-credentials list (`forbidden_phase1`)

The matrix also has a `forbidden_phase1` block — credentials that no Phase 1 workflow may reference. This currently includes Postiz and listmonk credentials that will only appear in Phase 2+. The audit hard-fails if any workflow imports a forbidden credential, regardless of its `allow` list.

## Why this exists

The outreach pipeline crosses a security boundary at approval — drafts are AI-generated, but anything that reaches publishing has been approved by a human. A misconfigured workflow that picks up the wrong credential could bypass that gate (e.g., the discover workflow accidentally getting Slack DM access could spam the operator). The audit enforces the boundary procedurally so n8n's flexible permissions model doesn't quietly let it slip.
