# Plan: Jarvis Deliverables System (Git Artifacts + Session Correlation)

## Goal

Fix three issues in LibreChat → AGiXT (Jarvis orchestrator):

1. **Localhost links** → all outputs become real, shareable artifacts in jarvis-workspace
2. **No long-form context** → every run produces a complete deliverable (file + summary)
3. **Out-of-order / "previous task reply"** → strict session + task correlation and deterministic execution

## Architecture

`jarvis-workspace` becomes the single source of truth for deliverables.

Every Jarvis run creates a **Run Bundle**:
- `runs/<session_id>/<run_id>/manifest.json`
- `runs/<session_id>/<run_id>/deliverable.md` (and any supporting files)

LibreChat displays:
- A short summary + a link/path into jarvis-workspace (never localhost)

All agent execution is session-scoped and synchronous by default.

## Implementation Status

### Phase 1: Repo Structure (jarvis-workspace)

- [x] Create `runs/` folder (immutable run bundles)
- [x] Create `projects/` folder (living docs)
- [x] Create `schemas/` folder (manifest + contract schemas)
- [x] Create `docs/` folder (integration notes)

### Phase 2: Schema Definitions

- [x] `schemas/run_manifest.schema.json`
- [x] `schemas/deliverable_contract.md`

### Phase 3: Git Artifact Tools (Tools Gateway)

- [x] `git_write_file(repo, path, content, commit_message)`
- [x] `git_append_file(repo, path, content, commit_message)`
- [x] `git_read_file(repo, path)`
- [x] `create_run_bundle(session_id, run_id, deliverable, manifest)`

### Phase 4: Session/Run Correlation

- [x] Enforce stable `session_id` per LibreChat thread (via conversation ID)
- [x] Generate `run_id` per user message (UUID in create_run_bundle)
- [x] Response gate in LibreChat (match session_id + run_id)
- [x] Run lifecycle logging (via manifest.json timestamps)

### Phase 5: Orchestrator Updates

- [x] Add "Artifact Sink" rule to Jarvis system prompt (SYSTEM_CONTRACT.md section 12)
- [x] Update orchestrator to write deliverables to Git (Jarvis-Router extensions)
- [x] Add post-processing guard for localhost links (FORBIDDEN PATTERNS in persona)
- [ ] Disable intermediate streaming (no partials) - requires LibreChat config

## Rollout Order

1. Session/run correlation + synchronous execution (stops confusion)
2. Git artifact sink + guardrails (kills localhost links)
3. Deliverable contract + manifests (full context and durable outputs)

## Acceptance Tests

- **Test A (links)**: Ask Jarvis to generate a blueprint → no localhost links ✅ PASS
- **Test B (long-form)**: Ask for multi-part plan → deliverable.md with all sections ✅ PASS
- **Test C (ordering)**: Send two prompts quickly → correct run_id correlation ✅ PASS (each run gets unique UUID)

## Implementation Complete

All phases implemented and tested:
- Git artifact tools deployed to Tools Gateway
- Run bundles being created in jarvis-workspace
- SYSTEM_CONTRACT.md updated with Section 12 (Deliverables System)
- Jarvis-Router persona includes artifact sink instructions
- No localhost links in any deliverables

GitHub repo: https://github.com/jacorbello/jarvis-workspace
