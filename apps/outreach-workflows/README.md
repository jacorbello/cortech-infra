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
