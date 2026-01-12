# AGiXT Self-Improvement System Plan

**Status**: Draft v2 (Hardened)
**Author**: Claude (Infrastructure Assistant)
**Created**: 2026-01-10
**Revised**: 2026-01-10 (incorporated security hardening feedback)

---

## Executive Summary

This plan outlines a self-improvement system for AGiXT that enables:
1. Automated error detection via sanitized telemetry (not raw logs)
2. Solution proposals stored as Git-tracked markdown files
3. Human-in-the-loop approval via PR workflow
4. Patch-based controlled implementation with validation gates

**Primary Optimization Target**: **Stability** (fewer errors, reliable operation)
- Secondary: Performance (latency, cost)
- Tertiary: Capability (new features)

This prioritization ensures EvalAgent proposals are focused and actionable, not a noisy mix.

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Self-Improvement Loop (Hardened)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────┐    ┌───────────────┐    ┌─────────────────────────────┐ │
│  │   Monitor     │───▶│   Analyze     │───▶│   Propose                   │ │
│  │   (Telemetry) │    │   (EvalAgent) │    │   (Git markdown files)      │ │
│  └───────────────┘    └───────────────┘    └─────────────────────────────┘ │
│         │                    │                          │                   │
│         ▼                    ▼                          ▼                   │
│  ┌───────────────┐    ┌───────────────┐    ┌─────────────────────────────┐ │
│  │ JSONL Events  │    │ Redacted      │    │ proposals/YYYY/MM/<id>.md   │ │
│  │ (sanitized)   │    │ Summaries     │    │ Status changes = commits    │ │
│  └───────────────┘    └───────────────┘    └─────────────────────────────┘ │
│                                                         │                   │
│                                                         ▼                   │
│                       ┌─────────────────────────────────────────────────┐  │
│                       │  Human Review (LibreChat + Git PR)              │  │
│                       │  - Review proposal markdown                      │  │
│                       │  - Approve = merge PR / commit status change    │  │
│                       └─────────────────────────────────────────────────┘  │
│                                                         │                   │
│                                                         ▼                   │
│                       ┌─────────────────────────────────────────────────┐  │
│                       │  Controlled Apply (PR-based)                    │  │
│                       │  1. WriterAgent outputs unified diff            │  │
│                       │  2. Tools Gateway writes patch to branch        │  │
│                       │  3. Validation pipeline (lint + policy tests)   │  │
│                       │  4. Human merges PR                             │  │
│                       │  5. Deploy pulls latest, restarts services      │  │
│                       └─────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Components

### 2.1 Telemetry Collection (Sanitized)

**Critical Rule**: EvalAgent never sees raw conversation logs or secrets.

**New Component**: `telemetry/`

```
jarvis/telemetry/
├── collector.py         # Extract structured events from logs
├── sanitizer.py         # Redact secrets, IPs, paths
├── schemas.py           # JSONL event schemas
└── extract.sh           # Daily extraction wrapper
```

**Telemetry Event Schema** (JSONL):
```json
{
  "timestamp": "2026-01-10T14:32:00Z",
  "event_type": "tool_call",
  "agent": "ResearchAgent",
  "tool": "web_search",
  "success": false,
  "error_code": "TIMEOUT",
  "error_message": "Request timed out after 30s",
  "latency_ms": 30000,
  "session_id": "abc123"
}
```

**Event Types Captured**:
| Event Type | Fields | Purpose |
|------------|--------|---------|
| `tool_call` | agent, tool, success, error_code, latency_ms | Track tool reliability |
| `user_correction` | agent, correction_type (not raw text) | Detect response quality issues |
| `task_failure` | task_name, error_category, retry_count | Scheduled task health |
| `feedback` | agent, thumbs_up/down, session_id | User satisfaction signal |
| `escalation` | agent, reason_category | Capability gap detection |

**Sanitization Rules**:
- API keys/tokens: replaced with `[REDACTED_KEY]`
- IP addresses: generalized to `192.168.x.x` or `[EXTERNAL_IP]`
- File paths: truncated to allowlisted prefixes only
- URLs: domain preserved, path/query stripped unless allowlisted
- User content: not captured (only metadata about corrections)

**Scheduled Task**: `telemetry-extract`
| Attribute | Value |
|-----------|-------|
| Schedule | Daily at 1 AM |
| Script | `telemetry/extract.sh` |
| Output | `telemetry/events/YYYY-MM-DD.jsonl` |
| Retention | 30 days rolling |

---

### 2.2 Self-Evaluation System

**New Agent**: `EvalAgent`

| Attribute | Value |
|-----------|-------|
| Provider | Anthropic |
| Model | claude-sonnet-4-5 |
| Purpose | Analyze telemetry, identify stability improvements |
| Extensions | None (pure reasoning) |
| Input | Telemetry JSONL + error reports (never raw logs) |

**Evaluation Focus** (Stability-first):
1. **Error Patterns**: Recurring failures, timeout clusters
2. **Tool Reliability**: Success rates by tool/agent
3. **User Corrections**: Frequency of follow-up requests
4. **Task Health**: Scheduled task failure trends
5. **Latency Anomalies**: P95 degradation

**Scheduled Task**: `self-eval`

| Attribute | Value |
|-----------|-------|
| Schedule | Daily at 2 AM |
| Agent | EvalAgent |
| Input | `telemetry/events/YYYY-MM-DD.jsonl`, `reports/errors/*.json` |
| Output | Proposal markdown files (if issues found) |

**Evaluation Prompt Template**:
```
You are reviewing sanitized telemetry from the past 24 hours.
Your optimization priority is: STABILITY > PERFORMANCE > CAPABILITY.

Analyze the following telemetry events and error reports.
Identify issues that impact system reliability.

For each issue worth addressing, output a proposal in the specified format.
Only propose changes if:
- The issue occurred 3+ times, OR
- The issue is severity:critical, OR
- There's a clear pattern indicating systemic problem

Do NOT propose:
- New features or capabilities (unless directly fixing errors)
- Performance optimizations (unless causing failures)
- Cosmetic changes

Telemetry data:
{telemetry_jsonl}

Error reports:
{error_reports_json}
```

---

### 2.3 Proposal System (Git-Based)

**No separate service.** Proposals are markdown files tracked in Git.

**Directory Structure**:
```
jarvis/proposals/
├── YYYY/
│   └── MM/
│       ├── <uuid>-short-title.md    # Proposal file
│       └── ...
├── templates/
│   ├── bugfix.md
│   ├── optimization.md
│   └── enhancement.md
└── index.md                          # Auto-generated listing
```

**Proposal File Format**:
```markdown
# Proposal: <title>

**ID**: <uuid>
**Created**: <timestamp>
**Status**: pending | approved | rejected | implemented
**Category**: bugfix | optimization | enhancement
**Severity**: critical | high | medium | low
**Author**: EvalAgent

---

## Problem Statement
<What's broken or suboptimal>

## Evidence
- Telemetry event count: X failures in Y hours
- Error pattern: <redacted error string>
- Affected agent(s): <list>

## Root Cause Analysis
<Why this is happening>

## Proposed Solution
<What to change>

## Unified Diff
```diff
--- a/path/to/file.yaml
+++ b/path/to/file.yaml
@@ -10,3 +10,5 @@
 existing line
-removed line
+added line
+another added line
```

## Affected Files
- `path/to/file.yaml`

## Risk Assessment
<What could go wrong>

## Rollback Plan
```bash
git revert <commit-sha>
```

## Validation Checklist
- [ ] yamllint passes
- [ ] JSON schema valid (if applicable)
- [ ] Policy tests pass
- [ ] No forbidden paths modified

---

## Review

**Reviewed by**: <human name>
**Reviewed at**: <timestamp>
**Decision**: approved | rejected
**Notes**: <optional comments>

---

## Implementation Log

<Populated after implementation>
```

**Status Transitions** (via Git commits):
```
pending → approved    # Human commits status change
pending → rejected    # Human commits with rejection reason
approved → implemented # Automation commits after successful apply
implemented → reverted # If rollback triggered
```

---

### 2.4 Human Approval Flow

**Primary Channel**: LibreChat + Git

**Flow**:
1. EvalAgent creates proposal markdown file
2. Tools Gateway commits to `proposals/` branch (not main)
3. Webhook notifies human via LibreChat: "New proposal: [title] - review at [link]"
4. Human reviews proposal markdown
5. Human either:
   - Approves: commits status change to `approved`, or
   - Rejects: commits status change with reason
6. For approved proposals: human merges proposal branch to main

**LibreChat Commands** (parsed by bot):
- `proposals list` - Show pending proposals
- `proposals show <id>` - Display proposal details
- `proposals approve <id>` - Mark approved (triggers status commit)
- `proposals reject <id> <reason>` - Mark rejected with reason

**Batching** (Alert Fatigue Prevention):
- Critical severity: immediate notification
- High severity: batched hourly
- Medium/Low severity: daily digest at 9 AM
- If >5 proposals pending, send summary instead of individual notifications

**Backoff Rules**:
- If 3 consecutive proposals rejected: pause self-eval for 48h
- If implementation fails: pause that category for 24h
- If error rate spikes post-implementation: halt all proposals, alert human

---

### 2.5 Controlled Implementation (PR-Based)

**Key Principle**: WriterAgent outputs diffs only, never full file rewrites.

**Implementation Pipeline**:

```
┌─────────────────┐
│ Approved        │
│ Proposal        │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. WriterAgent: Generate Unified Diff                       │
│    - Read current file from pinned base commit              │
│    - Output diff only (not full file)                       │
│    - Diff must match proposal's diff_preview                │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Tools Gateway: Write Patch to Branch                     │
│    POST /actions/write_patch                                │
│    - Creates feature branch: jarvis/proposal-<id>           │
│    - Writes .patch file to staging                          │
│    - Applies patch with: git apply --check (dry run)        │
│    - If clean: git apply && git add && git commit           │
│    - Commit message: "chore(jarvis): <proposal-title>"      │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Validation Pipeline                                      │
│    - yamllint (for .yaml/.yml files)                        │
│    - jsonschema validation (for config JSON)                │
│    - Policy tests (see below)                               │
│    - shellcheck (for .sh files)                             │
│    - python -m py_compile (for .py files)                   │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Open PR / Notify Human                                   │
│    - If validation passes: open PR (or notify ready)        │
│    - If validation fails: mark proposal blocked, notify     │
│    - PR description includes proposal summary + diff        │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. Human Merges PR                                          │
│    - Review diff one more time                              │
│    - Merge to main                                          │
│    - Triggers deploy webhook                                │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. Deploy & Monitor                                         │
│    - Pull latest to /opt/jarvis                             │
│    - Restart affected services (if needed)                  │
│    - Run provision.py (if agents.yaml changed)              │
│    - Monitor error rate for 1 hour                          │
│    - If spike: auto-revert, alert human                     │
└─────────────────────────────────────────────────────────────┘
```

**New Tools Gateway Actions**:

1. `POST /actions/write_patch`
   ```json
   {
     "proposal_id": "uuid",
     "base_commit": "sha",
     "patch_content": "unified diff string"
   }
   ```
   - Validates patch applies cleanly
   - Creates branch, applies, commits
   - Returns branch name and commit SHA

2. `POST /actions/validate_branch`
   ```json
   {
     "branch": "jarvis/proposal-<id>"
   }
   ```
   - Runs full validation pipeline
   - Returns pass/fail with details

3. `POST /actions/open_pr`
   ```json
   {
     "branch": "jarvis/proposal-<id>",
     "proposal_id": "uuid"
   }
   ```
   - Creates PR with proposal content as description
   - Returns PR URL

---

### 2.6 Policy Tests

**Purpose**: Catch dangerous changes before they reach human review.

**Test File**: `jarvis/tests/policy_test.py`

```python
"""
Policy tests for self-improvement proposals.
Run on every proposal branch before PR creation.
"""

import yaml
import subprocess
from pathlib import Path

FORBIDDEN_PATHS = [
    "docker-compose.yml",
    ".env",
    ".env.example",  # template reveals structure
    "SYSTEM_CONTRACT.md",
    "tools-gateway/main.py",
    "tools-gateway/actions.yaml",  # allowlist logic
    "rag-ingestion/ingest.py",
    "agents/provision.py",
    "agents/generate_api_key.py",
]

ALLOWED_EXTERNAL_URLS = [
    "api.openai.com",
    "api.anthropic.com",
    "github.com",
]

def test_no_forbidden_paths_modified():
    """No changes to critical infrastructure files."""
    result = subprocess.run(
        ["git", "diff", "--name-only", "main...HEAD"],
        capture_output=True, text=True
    )
    changed_files = result.stdout.strip().split("\n")

    for path in changed_files:
        assert path not in FORBIDDEN_PATHS, \
            f"Forbidden path modified: {path}"

def test_no_new_tool_endpoints():
    """No new endpoints added to tools-gateway."""
    # This would fail anyway due to forbidden path,
    # but explicit test documents intent
    pass

def test_no_privilege_escalation_in_agents():
    """Agents cannot grant themselves new tools/extensions."""
    agents_file = Path("agents/agents.yaml")
    if not agents_file.exists():
        return

    with open(agents_file) as f:
        current = yaml.safe_load(f)

    result = subprocess.run(
        ["git", "show", "main:agents/agents.yaml"],
        capture_output=True, text=True
    )
    original = yaml.safe_load(result.stdout)

    for agent_name, agent_config in current.get("agents", {}).items():
        original_agent = original.get("agents", {}).get(agent_name, {})

        current_extensions = set(agent_config.get("extensions", []))
        original_extensions = set(original_agent.get("extensions", []))

        new_extensions = current_extensions - original_extensions
        assert not new_extensions, \
            f"Agent {agent_name} granted new extensions: {new_extensions}"

def test_no_new_allowed_paths():
    """Cannot expand file read allowlist without manual review."""
    actions_file = Path("tools-gateway/actions.yaml")
    # This file is forbidden, so changes would fail earlier
    # But if somehow reached, block new paths
    pass

def test_no_external_urls_added():
    """New external URLs require manual approval."""
    result = subprocess.run(
        ["git", "diff", "main...HEAD"],
        capture_output=True, text=True
    )
    diff = result.stdout

    # Simple URL pattern detection
    import re
    urls = re.findall(r'https?://([^/\s"\']+)', diff)

    for url in urls:
        domain = url.split('/')[0]
        if domain not in ALLOWED_EXTERNAL_URLS:
            # Allow if it's a removal (line starts with -)
            # This is a simplified check
            assert f"-.*{url}" in diff or domain in ALLOWED_EXTERNAL_URLS, \
                f"New external URL requires approval: {url}"

def test_system_contract_unchanged():
    """SYSTEM_CONTRACT.md must never be modified."""
    result = subprocess.run(
        ["git", "diff", "--name-only", "main...HEAD"],
        capture_output=True, text=True
    )
    assert "SYSTEM_CONTRACT.md" not in result.stdout
```

**Run Command**:
```bash
cd /opt/jarvis && python -m pytest tests/policy_test.py -v
```

---

### 2.7 Enhancement Discovery

**Scheduled Task**: `enhancement-scan`

| Attribute | Value |
|-----------|-------|
| Schedule | Weekly (Sundays at 6 AM) |
| Agent | PlannerAgent |
| Focus | Stability improvements only (per optimization priority) |

**Scan Scope** (Stability-focused):
1. Recurring error patterns not yet addressed
2. Flaky scheduled tasks (intermittent failures)
3. RAG index staleness (documents older than 30 days)
4. Agent prompt drift from SYSTEM_CONTRACT principles

**Not in Scope** (requires manual request):
- New feature proposals
- Performance optimizations (unless causing failures)
- Capability expansions

---

## 3. Safety Guardrails

### 3.1 Change Scope Limits

**Allowed Self-Modifications** (via proposal system):
- Agent persona/prompt text in `agents/agents.yaml` (no extension changes)
- Scheduled task prompts in `scheduled_tasks.yaml`
- Documentation in `docs/`
- Proposal templates in `proposals/templates/`

**Forbidden Self-Modifications** (require manual human edits):
- `docker-compose.yml` (service topology)
- `.env` / `.env.example` (secrets, configuration)
- `SYSTEM_CONTRACT.md` (governance document)
- `tools-gateway/main.py` (action implementation code)
- `tools-gateway/actions.yaml` (allowlist configuration)
- `rag-ingestion/ingest.py` (indexing logic)
- `agents/provision.py` (provisioning logic)
- `agents/generate_api_key.py` (credential generation)
- Any network/database configuration
- Any file outside `/opt/jarvis` or `/root/repos/infrastructure/jarvis`

**Privilege Escalation Rule**:
> No agent may grant itself or another agent new capabilities, tools, extensions,
> or access permissions, directly or indirectly. This includes:
> - Adding extensions to agent configs
> - Adding paths to file allowlists
> - Adding webhook endpoints
> - Modifying tool gateway code
> - Creating new scheduled tasks that call restricted tools

### 3.2 Approval Requirements

| Change Type | Auto-Apply | Human Approval | Notes |
|-------------|------------|----------------|-------|
| Typo fix in docs | No | Single | All changes need review |
| Agent prompt tuning | No | Single | Must not add capabilities |
| Scheduled task prompt | No | Single | Must not change schedule |
| New documentation | No | Single | - |
| Agent extension change | FORBIDDEN | N/A | Manual edit only |
| Allowlist modification | FORBIDDEN | N/A | Manual edit only |
| Infrastructure code | FORBIDDEN | N/A | Manual edit only |

### 3.3 Automatic Safeguards

**Rollback Triggers**:
- Validation pipeline fails → branch not merged, proposal blocked
- Error rate increases >25% within 1 hour post-deploy → auto-revert
- Any agent reports repeated failures → halt proposals, alert human
- Human triggers manual rollback

**Circuit Breakers**:
- 3 consecutive proposal rejections → pause self-eval 48h
- Implementation failure → pause that category 24h
- Auto-revert triggered → pause all proposals, require manual reset

---

## 4. Implementation Phases

### Phase 1: Telemetry Foundation
- [ ] Create `telemetry/` directory structure
- [ ] Implement `collector.py` - extract events from logs
- [ ] Implement `sanitizer.py` - redact secrets/IPs/paths
- [ ] Define JSONL schemas in `schemas.py`
- [ ] Create `extract.sh` wrapper script
- [ ] Add `telemetry-extract` scheduled task
- [ ] Test sanitization with real log samples

### Phase 2: Self-Evaluation
- [ ] Add EvalAgent to `agents/agents.yaml`
- [ ] Create `self-eval` scheduled task
- [ ] Write evaluation prompt template (stability-focused)
- [ ] Create proposal markdown templates
- [ ] Test EvalAgent output format on sample telemetry
- [ ] Implement proposal file creation in `proposals/`

### Phase 3: Git-Based Proposal Workflow
- [ ] Create `proposals/` directory structure
- [ ] Implement proposal index generation
- [ ] Add LibreChat command parsing for proposal management
- [ ] Implement batching/digest logic for notifications
- [ ] Test proposal creation → notification flow

### Phase 4: Validation Pipeline
- [ ] Write `tests/policy_test.py` with all policy checks
- [ ] Integrate yamllint, jsonschema validation
- [ ] Add shellcheck for shell scripts
- [ ] Add py_compile check for Python
- [ ] Test validation on intentionally bad patches

### Phase 5: PR-Based Implementation
- [ ] Add `write_patch` action to Tools Gateway
- [ ] Add `validate_branch` action
- [ ] Add `open_pr` action (or issue-with-patch fallback)
- [ ] Implement branch creation and patch application
- [ ] Test end-to-end: proposal → patch → validation → PR
- [ ] Implement post-deploy monitoring and auto-revert

### Phase 6: Enhancement Discovery
- [ ] Create `enhancement-scan` scheduled task
- [ ] Focus on stability patterns only
- [ ] Integrate with proposal workflow
- [ ] Test on historical data

---

## 5. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Telemetry coverage | >90% of tool calls captured | Daily audit |
| Sanitization accuracy | 0 secret leaks | Weekly manual review |
| Proposal quality | >60% approval rate | Monthly |
| Validation catch rate | 100% of policy violations blocked | Per proposal |
| Mean time to review | <24h for critical, <72h for others | Per proposal |
| Rollback rate | <10% of implemented proposals | Monthly |
| System stability | Error rate trend decreasing | Weekly |

---

## 6. Files to Create/Modify

### New Files
```
jarvis/
├── telemetry/
│   ├── collector.py
│   ├── sanitizer.py
│   ├── schemas.py
│   └── extract.sh
├── proposals/
│   ├── templates/
│   │   ├── bugfix.md
│   │   ├── optimization.md
│   │   └── enhancement.md
│   └── index.md
├── tests/
│   └── policy_test.py
└── scripts/
    └── deploy-proposal.sh
```

### Modified Files
```
jarvis/
├── agents/agents.yaml              # Add EvalAgent
├── scheduler/scheduled_tasks.yaml  # Add telemetry-extract, self-eval
├── scheduler/crontab               # New cron entries
└── tools-gateway/main.py           # Add write_patch, validate_branch, open_pr
```

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Secret leak via telemetry | Low | Critical | Sanitization layer, manual review |
| Privilege escalation attempt | Low | Critical | Policy tests, forbidden paths |
| Bad patch breaks system | Medium | High | Validation pipeline, PR review, auto-revert |
| Alert fatigue | Medium | Medium | Batching, severity thresholds, backoff |
| EvalAgent proposes noise | Medium | Low | Stability-first priority, rejection feedback |
| Git conflicts on proposals branch | Low | Low | Single-proposal branches, clean merge |

---

## 8. Decisions Made

Based on review feedback, the following decisions are locked in:

1. **Notification Channel**: LibreChat primary, with webhook backup
2. **Approval Workflow**: Single approval for all (no auto-apply)
3. **Auto-Apply**: Disabled - all changes require human approval
4. **Rollback Window**: 1 hour monitoring post-deploy
5. **Proposal Retention**: Forever (Git history)
6. **Optimization Priority**: Stability > Performance > Capability

---

## 9. Appendix: Example Flow (Revised)

```
1. [01:00] telemetry-extract runs, produces sanitized JSONL
2. [02:00] self-eval task runs, EvalAgent analyzes telemetry
3. [02:05] EvalAgent identifies: "ResearchAgent web_search timeout 8 times"
4. [02:06] EvalAgent creates proposal file:
   - proposals/2026/01/a1b2c3-increase-web-timeout.md
   - Category: bugfix
   - Severity: medium
   - Solution: Increase timeout in ResearchAgent prompt guidance
   - Diff: +1 line to agents.yaml persona
5. [02:07] Tools Gateway commits proposal to branch jarvis/proposal-a1b2c3
6. [09:00] Daily digest notification: "1 new proposal pending review"
7. [10:30] Human reads proposal in LibreChat or Git
8. [10:35] Human: "proposals approve a1b2c3"
9. [10:36] Status updated to approved, PR opened
10. [10:40] Human reviews PR diff, merges to main
11. [10:41] Deploy webhook fires:
    - git pull on /opt/jarvis
    - provision.py runs (agents.yaml changed)
12. [10:45] Monitoring begins (1 hour window)
13. [11:45] No error spike detected, proposal marked implemented
14. [11:46] Human notified: "Proposal a1b2c3 stable, implementation complete"
```

---

## 10. References

- [SYSTEM_CONTRACT.md](/root/repos/infrastructure/jarvis/SYSTEM_CONTRACT.md)
- [agents/agents.yaml](/root/repos/infrastructure/jarvis/agents/agents.yaml)
- [scheduler/scheduled_tasks.yaml](/root/repos/infrastructure/jarvis/scheduler/scheduled_tasks.yaml)
- [tools-gateway/main.py](/root/repos/infrastructure/jarvis/tools-gateway/main.py)
