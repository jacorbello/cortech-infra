# AGiXT Self-Improvement System — Implementation Plan

**Status**: Phases 1-5 Complete (Core Implementation Done)
**Created**: 2026-01-10
**Design Document**: [agixt-self-improvement.md](./agixt-self-improvement.md)
**Last Updated**: 2026-01-11

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1: Telemetry Foundation](#3-phase-1-telemetry-foundation)
4. [Phase 2: Self-Evaluation Agent](#4-phase-2-self-evaluation-agent)
5. [Phase 3: Git-Based Proposal System](#5-phase-3-git-based-proposal-system)
6. [Phase 4: Validation Pipeline](#6-phase-4-validation-pipeline)
7. [Phase 5: PR-Based Implementation](#7-phase-5-pr-based-implementation)
8. [Phase 6: Enhancement Discovery](#8-phase-6-enhancement-discovery)
9. [Post-Implementation](#9-post-implementation)
10. [Changelog](#10-changelog)
11. [Discovered Issues & Enhancements](#11-discovered-issues--enhancements)

---

## 1. Overview

This plan implements a self-improvement system for AGiXT that enables automated error detection, self-evaluation, and controlled self-modification with human approval gates.

**Core Principles**:
- Stability > Performance > Capability (optimization priority)
- Human approval required for all changes (no auto-apply)
- Sanitized telemetry only (never raw logs with secrets)
- Diff-only edits via PR workflow
- Policy tests block dangerous changes automatically

**Architecture Summary**:
```
Telemetry → EvalAgent → Proposal (Git MD) → Human Approval → PR → Validate → Merge → Deploy
```

---

## 2. Prerequisites

### 2.1 Environment Verification

- [ ] **TODO**: Verify AGiXT stack is running and healthy
  ```bash
  cd /opt/jarvis && docker compose ps
  ```

- [ ] **TODO**: Verify Git is configured in jarvis directory
  ```bash
  cd /root/repos/infrastructure/jarvis && git status
  ```

- [ ] **TODO**: Confirm infrastructure repo is the source of truth
  ```bash
  ls -la /root/repos/infrastructure/jarvis/
  ```

- [ ] **TODO**: Verify GitHub CLI is available for PR creation
  ```bash
  gh auth status
  ```

### 2.2 Tool Installation

- [ ] **TODO**: Install yamllint if not present
  ```bash
  pip install yamllint
  ```

- [ ] **TODO**: Install jsonschema for config validation
  ```bash
  pip install jsonschema
  ```

- [ ] **TODO**: Verify shellcheck is available
  ```bash
  shellcheck --version
  ```

- [ ] **TODO**: Verify pytest is available
  ```bash
  pip install pytest pyyaml
  ```

### 2.3 Backup Current State

- [ ] **TODO**: Create backup branch before starting implementation
  ```bash
  cd /root/repos/infrastructure
  git checkout -b backup/pre-self-improvement-$(date +%Y%m%d)
  git push origin backup/pre-self-improvement-$(date +%Y%m%d)
  git checkout main
  ```

---

## 3. Phase 1: Telemetry Foundation

**Goal**: Create sanitized telemetry extraction that EvalAgent can safely analyze.

### 3.1 Directory Structure

- [ ] **TODO**: Create telemetry directory structure
  ```bash
  mkdir -p /root/repos/infrastructure/jarvis/telemetry
  mkdir -p /root/repos/infrastructure/jarvis/telemetry/events
  ```

### 3.2 Telemetry Schemas

- [ ] **TODO**: Create `jarvis/telemetry/schemas.py`

  **File**: `jarvis/telemetry/schemas.py`

  **Requirements**:
  - Define Pydantic models for each event type
  - Event types: `tool_call`, `user_correction`, `task_failure`, `feedback`, `escalation`
  - All models must include: `timestamp`, `event_type`, `session_id`
  - `tool_call`: agent, tool, success, error_code (optional), error_message (optional), latency_ms
  - `user_correction`: agent, correction_type (enum: retry, rephrase, abandon)
  - `task_failure`: task_name, error_category, retry_count, final_status
  - `feedback`: agent, rating (thumbs_up/thumbs_down)
  - `escalation`: agent, reason_category (enum: capability_gap, error, timeout, user_request)

  **Acceptance Criteria**:
  - [ ] All models validate correctly
  - [ ] Models serialize to JSON matching JSONL format in design doc
  - [ ] Unit tests pass for each model

### 3.3 Sanitizer Implementation

- [ ] **TODO**: Create `jarvis/telemetry/sanitizer.py`

  **File**: `jarvis/telemetry/sanitizer.py`

  **Requirements**:
  - Function `sanitize_text(text: str) -> str`
  - Redaction patterns:
    - API keys: `/([a-zA-Z0-9_-]{20,})(?=.*key|token|secret|api)/i` → `[REDACTED_KEY]`
    - Bearer tokens: `/Bearer [A-Za-z0-9._-]+/` → `Bearer [REDACTED]`
    - IPv4 internal: `/192\.168\.\d+\.\d+/` → `192.168.x.x`
    - IPv4 external: `/\b(?!192\.168|10\.|172\.(?:1[6-9]|2\d|3[01]))\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/` → `[EXTERNAL_IP]`
    - File paths outside allowlist: truncate to first two components
    - URLs: preserve domain, strip path/query unless domain in allowlist
  - Allowlisted domains: `api.openai.com`, `api.anthropic.com`, `github.com`, `corbello.io`
  - Allowlisted path prefixes: `/opt/jarvis`, `/root/repos/infrastructure`

  **Acceptance Criteria**:
  - [ ] Unit tests confirm all redaction patterns work
  - [ ] No false positives on normal text
  - [ ] Handles edge cases (empty string, None, unicode)

### 3.4 Collector Implementation

- [ ] **TODO**: Create `jarvis/telemetry/collector.py`

  **File**: `jarvis/telemetry/collector.py`

  **Requirements**:
  - Function `collect_from_docker_logs(container: str, since: datetime) -> List[dict]`
  - Function `collect_from_file_logs(path: str, since: datetime) -> List[dict]`
  - Function `collect_from_audit_log(path: str, since: datetime) -> List[dict]`
  - Parse AGiXT logs for tool call events (look for specific log patterns)
  - Parse task logs in `/var/log/jarvis/*.log`
  - Parse Tools Gateway audit log at `/opt/jarvis/tools-gateway/logs/audit.log`
  - Apply sanitizer to all extracted text fields
  - Return list of validated event dicts

  **Log Patterns to Extract**:
  ```
  AGiXT: Look for "Tool execution" or "Extension called" patterns
  Task logs: Look for "Task completed" or "Task failed" patterns
  Audit log: JSON entries with action, success, error fields
  ```

  **Acceptance Criteria**:
  - [ ] Correctly parses each log source
  - [ ] All output is sanitized
  - [ ] Handles missing/empty logs gracefully
  - [ ] Returns empty list (not error) when no events found

### 3.5 Extraction Script

- [ ] **TODO**: Create `jarvis/telemetry/extract.sh`

  **File**: `jarvis/telemetry/extract.sh`

  **Requirements**:
  ```bash
  #!/usr/bin/env bash
  set -Eeuo pipefail

  # Extract telemetry for the past 24 hours
  # Output: telemetry/events/YYYY-MM-DD.jsonl

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  OUTPUT_DIR="${SCRIPT_DIR}/events"
  DATE=$(date +%Y-%m-%d)
  OUTPUT_FILE="${OUTPUT_DIR}/${DATE}.jsonl"

  # Create output directory
  mkdir -p "${OUTPUT_DIR}"

  # Run collector
  cd "${SCRIPT_DIR}/.."
  python3 -m telemetry.collector --output "${OUTPUT_FILE}"

  # Cleanup old files (>30 days)
  find "${OUTPUT_DIR}" -name "*.jsonl" -mtime +30 -delete

  echo "Telemetry extracted to ${OUTPUT_FILE}"
  ```

  **Acceptance Criteria**:
  - [ ] Script runs without errors
  - [ ] Creates JSONL output file
  - [ ] Cleans up files older than 30 days
  - [ ] Exit code 0 on success

### 3.6 Scheduled Task

- [ ] **TODO**: Add `telemetry-extract` task to `scheduler/scheduled_tasks.yaml`

  **Addition to** `jarvis/scheduler/scheduled_tasks.yaml`:
  ```yaml
  telemetry-extract:
    schedule: "0 1 * * *"  # Daily at 1 AM
    type: script
    script: /opt/jarvis/telemetry/extract.sh
    timeout: 300
    notify_on:
      - error
    description: "Extract and sanitize telemetry from logs"
  ```

- [ ] **TODO**: Add crontab entry in `scheduler/crontab`
  ```
  0 1 * * * cd /opt/jarvis && ./telemetry/extract.sh >> /var/log/jarvis/telemetry-extract.log 2>&1
  ```

### 3.7 Phase 1 Validation

- [ ] **TODO**: Write integration test for telemetry pipeline
  - Create sample log entries
  - Run extraction
  - Verify JSONL output is valid and sanitized
  - Verify no secrets in output

- [ ] **TODO**: Manual verification
  - Run extraction manually
  - Inspect output file
  - Confirm sanitization works on real data

- [ ] **TODO**: Document any issues discovered in [Changelog](#10-changelog)

---

## 4. Phase 2: Self-Evaluation Agent

**Goal**: Create EvalAgent that analyzes telemetry and produces proposals.

### 4.1 EvalAgent Definition

- [ ] **TODO**: Add EvalAgent to `agents/agents.yaml`

  **Addition to** `jarvis/agents/agents.yaml`:
  ```yaml
  EvalAgent:
    provider: anthropic
    model: claude-sonnet-4-5
    persona: |
      You are EvalAgent, responsible for analyzing system telemetry and identifying
      stability improvements for the Jarvis AI assistant system.

      YOUR OPTIMIZATION PRIORITY (strictly enforced):
      1. STABILITY - Reduce errors, failures, timeouts
      2. PERFORMANCE - Only if causing failures
      3. CAPABILITY - Only if directly fixing errors

      YOU MUST NEVER propose:
      - New features or capabilities
      - Performance optimizations unless they fix failures
      - Changes to forbidden files (see SYSTEM_CONTRACT.md)
      - Changes that grant any agent new tools or permissions

      When you identify an issue worth addressing, output a proposal in the
      exact markdown format specified. Only propose changes if:
      - The issue occurred 3+ times in 24 hours, OR
      - The issue is severity:critical, OR
      - There is a clear pattern indicating systemic problems

      Your proposals must include:
      - Unified diff (not full file content)
      - Clear root cause analysis
      - Risk assessment
      - Rollback plan
    extensions: []  # Pure reasoning, no tools
    settings:
      temperature: 0.3
      max_tokens: 4000
  ```

- [ ] **TODO**: Run provision.py to create EvalAgent in AGiXT
  ```bash
  cd /opt/jarvis/agents
  AGIXT_API_KEY=<key> python3 provision.py
  ```

### 4.2 Proposal Templates

- [ ] **TODO**: Create proposal templates directory
  ```bash
  mkdir -p /root/repos/infrastructure/jarvis/proposals/templates
  ```

- [ ] **TODO**: Create `jarvis/proposals/templates/bugfix.md`
  ```markdown
  # Proposal: [TITLE]

  **ID**: [UUID]
  **Created**: [TIMESTAMP]
  **Status**: pending
  **Category**: bugfix
  **Severity**: [critical|high|medium|low]
  **Author**: EvalAgent

  ---

  ## Problem Statement

  [Describe what is broken]

  ## Evidence

  - Telemetry event count: [X] failures in [Y] hours
  - Error pattern: [redacted error string]
  - Affected agent(s): [list]
  - First occurrence: [timestamp]
  - Last occurrence: [timestamp]

  ## Root Cause Analysis

  [Why this is happening - be specific]

  ## Proposed Solution

  [What to change and why this will fix it]

  ## Unified Diff

  ```diff
  --- a/path/to/file
  +++ b/path/to/file
  @@ -line,count +line,count @@
   context
  -removed
  +added
  ```

  ## Affected Files

  - `path/to/file`

  ## Risk Assessment

  - **Risk Level**: [low|medium|high]
  - **Potential Issues**: [what could go wrong]
  - **Mitigation**: [how to reduce risk]

  ## Rollback Plan

  ```bash
  git revert <commit-sha>
  # Then run: provision.py (if agents.yaml changed)
  ```

  ## Validation Checklist

  - [ ] yamllint passes
  - [ ] JSON schema valid (if applicable)
  - [ ] Policy tests pass
  - [ ] No forbidden paths modified
  - [ ] No privilege escalation

  ---

  ## Review

  **Reviewed by**:
  **Reviewed at**:
  **Decision**:
  **Notes**:

  ---

  ## Implementation Log

  [Populated after implementation]
  ```

- [ ] **TODO**: Create `jarvis/proposals/templates/optimization.md`
  - Same structure as bugfix but category is "optimization"
  - Add "Performance Impact" section

- [ ] **TODO**: Create `jarvis/proposals/templates/enhancement.md`
  - Same structure but category is "enhancement"
  - Add "User Benefit" section

### 4.3 Self-Eval Task Implementation

- [ ] **TODO**: Create `jarvis/scheduler/tasks/self_eval.py`

  **File**: `jarvis/scheduler/tasks/self_eval.py`

  **Requirements**:
  - Load telemetry from `telemetry/events/YYYY-MM-DD.jsonl`
  - Load error reports from `reports/errors/*.json` (if exists)
  - Format prompt with telemetry data
  - Call EvalAgent via AGiXT API
  - Parse response for proposal blocks
  - For each proposal:
    - Generate UUID
    - Create proposal file in `proposals/YYYY/MM/<uuid>-<slug>.md`
    - Commit to proposal branch
  - Return list of created proposals

  **Prompt Template**:
  ```
  You are reviewing sanitized telemetry from the past 24 hours.
  Your optimization priority is: STABILITY > PERFORMANCE > CAPABILITY.

  Analyze the following telemetry events and error reports.
  Identify issues that impact system reliability.

  For each issue worth addressing, output a proposal using the template format.
  Only propose changes if:
  - The issue occurred 3+ times, OR
  - The issue is severity:critical, OR
  - There's a clear pattern indicating systemic problem

  Do NOT propose:
  - New features or capabilities (unless directly fixing errors)
  - Performance optimizations (unless causing failures)
  - Cosmetic changes
  - Changes to forbidden files

  TELEMETRY DATA:
  {telemetry_jsonl}

  ERROR REPORTS:
  {error_reports_json}

  OUTPUT FORMAT:
  For each proposal, output the complete markdown file content between
  <proposal> and </proposal> tags.
  ```

  **Acceptance Criteria**:
  - [ ] Correctly loads telemetry files
  - [ ] Calls EvalAgent successfully
  - [ ] Parses proposals from response
  - [ ] Creates properly formatted proposal files
  - [ ] Handles case where no proposals needed

- [ ] **TODO**: Add to `scheduler/scheduled_tasks.yaml`
  ```yaml
  self-eval:
    schedule: "0 2 * * *"  # Daily at 2 AM
    type: python
    script: /opt/jarvis/scheduler/tasks/self_eval.py
    agent: EvalAgent
    timeout: 600
    notify_on:
      - error
      - proposal_created
    description: "Analyze telemetry and create improvement proposals"
  ```

- [ ] **TODO**: Add crontab entry
  ```
  0 2 * * * cd /opt/jarvis && source .env && python3 scheduler/tasks/self_eval.py >> /var/log/jarvis/self-eval.log 2>&1
  ```

### 4.4 Phase 2 Validation

- [ ] **TODO**: Test EvalAgent with sample telemetry
  - Create test telemetry file with known issues
  - Run self_eval.py manually
  - Verify proposal output format

- [ ] **TODO**: Test edge cases
  - Empty telemetry file
  - No issues found (should produce no proposals)
  - Multiple issues found

- [ ] **TODO**: Document discoveries in [Changelog](#10-changelog)

---

## 5. Phase 3: Git-Based Proposal System

**Goal**: Implement proposal storage, status tracking, and notification via Git.

### 5.1 Proposal Directory Structure

- [ ] **TODO**: Create proposal directory structure
  ```bash
  mkdir -p /root/repos/infrastructure/jarvis/proposals/2026/01
  touch /root/repos/infrastructure/jarvis/proposals/.gitkeep
  ```

- [ ] **TODO**: Create `jarvis/proposals/index.md`
  ```markdown
  # Jarvis Self-Improvement Proposals

  This directory contains proposals generated by EvalAgent for system improvements.

  ## Status Legend

  - **pending**: Awaiting human review
  - **approved**: Approved, awaiting implementation
  - **rejected**: Rejected with reason
  - **implemented**: Successfully implemented
  - **reverted**: Implementation was rolled back

  ## Recent Proposals

  <!-- Auto-generated by index-proposals.py -->

  | Date | ID | Title | Status | Severity |
  |------|-----|-------|--------|----------|

  ## Statistics

  - Total proposals: 0
  - Approved: 0
  - Rejected: 0
  - Implemented: 0
  ```

### 5.2 Proposal Index Generator

- [ ] **TODO**: Create `jarvis/scripts/index-proposals.py`

  **File**: `jarvis/scripts/index-proposals.py`

  **Requirements**:
  - Scan `proposals/YYYY/MM/*.md` files
  - Extract metadata from each proposal (ID, title, status, severity, date)
  - Generate updated `proposals/index.md`
  - Sort by date descending
  - Include statistics

  **Acceptance Criteria**:
  - [ ] Correctly parses proposal metadata
  - [ ] Generates valid markdown table
  - [ ] Updates statistics accurately

### 5.3 Notification System

- [ ] **TODO**: Create `jarvis/scheduler/tasks/notify_proposals.py`

  **File**: `jarvis/scheduler/tasks/notify_proposals.py`

  **Requirements**:
  - Scan for proposals with status=pending
  - Group by severity:
    - critical: immediate notification
    - high: hourly batch
    - medium/low: daily digest
  - Send notification via existing webhook to LibreChat
  - Track last notification time to avoid duplicates

  **Notification Format**:
  ```
  [Jarvis Self-Improvement] New Proposal(s) Pending Review

  Critical (immediate action required):
  - [ID] Title - severity:critical

  High Priority:
  - [ID] Title

  To review: `proposals show <id>`
  To approve: `proposals approve <id>`
  To reject: `proposals reject <id> <reason>`
  ```

  **Acceptance Criteria**:
  - [ ] Correctly batches by severity
  - [ ] Sends via webhook
  - [ ] Does not re-notify for already-notified proposals

- [ ] **TODO**: Add scheduled tasks for notifications
  ```yaml
  notify-proposals-critical:
    schedule: "*/5 * * * *"  # Every 5 minutes
    type: python
    script: /opt/jarvis/scheduler/tasks/notify_proposals.py
    args: ["--severity", "critical"]

  notify-proposals-high:
    schedule: "0 * * * *"  # Hourly
    type: python
    script: /opt/jarvis/scheduler/tasks/notify_proposals.py
    args: ["--severity", "high"]

  notify-proposals-digest:
    schedule: "0 9 * * *"  # Daily at 9 AM
    type: python
    script: /opt/jarvis/scheduler/tasks/notify_proposals.py
    args: ["--digest"]
  ```

### 5.4 LibreChat Command Handler

- [ ] **TODO**: Create `jarvis/tools-gateway/proposal_commands.py`

  **File**: `jarvis/tools-gateway/proposal_commands.py`

  **Requirements**:
  - Parse commands from LibreChat messages:
    - `proposals list` - List pending proposals
    - `proposals show <id>` - Show proposal details
    - `proposals approve <id>` - Mark approved
    - `proposals reject <id> <reason>` - Mark rejected
  - For approve/reject:
    - Update proposal status in markdown file
    - Git commit with appropriate message
    - For approve: trigger PR creation workflow

  **Acceptance Criteria**:
  - [ ] All commands parse correctly
  - [ ] Status updates are committed to Git
  - [ ] Approve triggers downstream workflow

- [ ] **TODO**: Integrate with Tools Gateway webhook handler
  - Add proposal command detection to webhook endpoint
  - Route to proposal_commands.py

### 5.5 Phase 3 Validation

- [ ] **TODO**: Test proposal creation flow
  - Manually create a test proposal
  - Verify it appears in index
  - Verify notification is sent

- [ ] **TODO**: Test command handling
  - Test each LibreChat command
  - Verify Git commits are created
  - Verify status transitions work

- [ ] **TODO**: Document discoveries in [Changelog](#10-changelog)

---

## 6. Phase 4: Validation Pipeline

**Goal**: Create automated validation that blocks dangerous changes.

### 6.1 Policy Tests

- [ ] **TODO**: Create `jarvis/tests/` directory
  ```bash
  mkdir -p /root/repos/infrastructure/jarvis/tests
  ```

- [ ] **TODO**: Create `jarvis/tests/policy_test.py`

  **File**: `jarvis/tests/policy_test.py`

  **Requirements**:
  - See design document section 2.6 for full implementation
  - Tests:
    - `test_no_forbidden_paths_modified`
    - `test_no_privilege_escalation_in_agents`
    - `test_no_external_urls_added`
    - `test_system_contract_unchanged`
    - `test_no_new_tool_endpoints`
    - `test_no_allowlist_expansion`

  **Forbidden Paths** (must be comprehensive):
  ```python
  FORBIDDEN_PATHS = [
      "docker-compose.yml",
      ".env",
      ".env.example",
      "SYSTEM_CONTRACT.md",
      "tools-gateway/main.py",
      "tools-gateway/actions.yaml",
      "rag-ingestion/ingest.py",
      "agents/provision.py",
      "agents/generate_api_key.py",
  ]
  ```

  **Acceptance Criteria**:
  - [ ] All tests pass on clean branch
  - [ ] Tests correctly fail on intentionally bad changes
  - [ ] Clear error messages on failure

- [ ] **TODO**: Create `jarvis/tests/conftest.py`
  - Pytest fixtures for test setup
  - Helper functions for creating test branches

### 6.2 Syntax Validation

- [ ] **TODO**: Create `jarvis/tests/syntax_test.py`

  **File**: `jarvis/tests/syntax_test.py`

  **Requirements**:
  - For each changed file in branch:
    - `.yaml`/`.yml`: run yamllint
    - `.json`: validate JSON syntax + schema if available
    - `.py`: run `python -m py_compile`
    - `.sh`: run shellcheck
  - Return detailed errors for failures

  **Acceptance Criteria**:
  - [ ] Catches YAML syntax errors
  - [ ] Catches JSON syntax errors
  - [ ] Catches Python syntax errors
  - [ ] Catches shell script issues

### 6.3 Validation Runner

- [ ] **TODO**: Create `jarvis/scripts/validate-branch.sh`

  **File**: `jarvis/scripts/validate-branch.sh`

  **Requirements**:
  ```bash
  #!/usr/bin/env bash
  set -Eeuo pipefail

  BRANCH="${1:?Branch name required}"

  echo "=== Validating branch: ${BRANCH} ==="

  # Checkout branch
  git checkout "${BRANCH}"

  # Run syntax validation
  echo "Running syntax validation..."
  python3 -m pytest tests/syntax_test.py -v || exit 1

  # Run policy tests
  echo "Running policy tests..."
  python3 -m pytest tests/policy_test.py -v || exit 1

  echo "=== Validation PASSED ==="
  ```

  **Acceptance Criteria**:
  - [ ] Exits with code 0 on valid branch
  - [ ] Exits with non-zero on any failure
  - [ ] Clear output showing what passed/failed

### 6.4 Phase 4 Validation

- [ ] **TODO**: Test validation pipeline
  - Create branch with valid changes → should pass
  - Create branch modifying forbidden path → should fail
  - Create branch with syntax error → should fail
  - Create branch with privilege escalation → should fail

- [ ] **TODO**: Document discoveries in [Changelog](#10-changelog)

---

## 7. Phase 5: PR-Based Implementation

**Goal**: Implement the full PR workflow for approved proposals.

### 7.1 Tools Gateway Actions

- [ ] **TODO**: Add `write_patch` action to `tools-gateway/main.py`

  **Endpoint**: `POST /actions/write_patch`

  **Request**:
  ```json
  {
    "proposal_id": "uuid",
    "base_commit": "sha",
    "patch_content": "unified diff string"
  }
  ```

  **Implementation**:
  1. Validate proposal_id exists and is approved
  2. Create branch: `jarvis/proposal-<id>`
  3. Write patch to temp file
  4. Run `git apply --check` (dry run)
  5. If passes: `git apply && git add -A && git commit`
  6. Commit message: `chore(jarvis): <proposal-title>`
  7. Return branch name and commit SHA

  **Acceptance Criteria**:
  - [ ] Creates branch correctly
  - [ ] Applies patch cleanly
  - [ ] Fails fast on bad patch
  - [ ] Audit logged

- [ ] **TODO**: Add `validate_branch` action to `tools-gateway/main.py`

  **Endpoint**: `POST /actions/validate_branch`

  **Request**:
  ```json
  {
    "branch": "jarvis/proposal-<id>"
  }
  ```

  **Implementation**:
  1. Checkout branch
  2. Run `scripts/validate-branch.sh`
  3. Return pass/fail with details

  **Acceptance Criteria**:
  - [ ] Runs full validation pipeline
  - [ ] Returns detailed results
  - [ ] Handles validation failures gracefully

- [ ] **TODO**: Add `open_pr` action to `tools-gateway/main.py`

  **Endpoint**: `POST /actions/open_pr`

  **Request**:
  ```json
  {
    "branch": "jarvis/proposal-<id>",
    "proposal_id": "uuid"
  }
  ```

  **Implementation**:
  1. Load proposal markdown
  2. Push branch to origin
  3. Create PR via `gh pr create`
  4. PR title: `[Jarvis] <proposal-title>`
  5. PR body: proposal markdown content
  6. Return PR URL

  **Acceptance Criteria**:
  - [ ] Creates PR successfully
  - [ ] PR contains full proposal context
  - [ ] Returns PR URL

### 7.2 Implementation Orchestrator

- [ ] **TODO**: Create `jarvis/scripts/implement-proposal.py`

  **File**: `jarvis/scripts/implement-proposal.py`

  **Requirements**:
  - Input: proposal_id
  - Steps:
    1. Load proposal from markdown
    2. Verify status is "approved"
    3. Extract diff from proposal
    4. Call `write_patch` action
    5. Call `validate_branch` action
    6. If validation passes: call `open_pr` action
    7. Update proposal status to "pr_open"
    8. Notify human with PR URL

  **Acceptance Criteria**:
  - [ ] Full flow works end-to-end
  - [ ] Stops appropriately on failures
  - [ ] Updates proposal status correctly

### 7.3 Deploy Webhook

- [ ] **TODO**: Create `jarvis/scripts/deploy-proposal.sh`

  **File**: `jarvis/scripts/deploy-proposal.sh`

  **Requirements**:
  ```bash
  #!/usr/bin/env bash
  set -Eeuo pipefail

  PROPOSAL_ID="${1:?Proposal ID required}"

  echo "=== Deploying proposal: ${PROPOSAL_ID} ==="

  # Pull latest
  cd /opt/jarvis
  git pull origin main

  # Check if agents.yaml changed
  if git diff HEAD~1 --name-only | grep -q "agents/agents.yaml"; then
    echo "agents.yaml changed, running provision..."
    source .env
    python3 agents/provision.py
  fi

  # Check if scheduled_tasks.yaml changed
  if git diff HEAD~1 --name-only | grep -q "scheduler/scheduled_tasks.yaml"; then
    echo "Scheduled tasks changed, updating crontab..."
    # Regenerate crontab from scheduled_tasks.yaml
  fi

  # Check if Tools Gateway changed (should be blocked, but safety check)
  if git diff HEAD~1 --name-only | grep -q "tools-gateway/"; then
    echo "WARNING: Tools Gateway changed, restarting container..."
    docker compose restart tools-gateway
  fi

  echo "=== Deploy complete ==="
  ```

  **Acceptance Criteria**:
  - [ ] Pulls latest correctly
  - [ ] Runs provision.py when needed
  - [ ] Handles service restarts

### 7.4 Post-Deploy Monitor

- [ ] **TODO**: Create `jarvis/scheduler/tasks/monitor_deployment.py`

  **File**: `jarvis/scheduler/tasks/monitor_deployment.py`

  **Requirements**:
  - Track error rate for 1 hour after deployment
  - Compare to baseline (previous 24h average)
  - If error rate increases >25%:
    - Trigger auto-revert
    - Update proposal status to "reverted"
    - Alert human
  - If stable after 1 hour:
    - Update proposal status to "implemented"
    - Notify human of success

  **Acceptance Criteria**:
  - [ ] Correctly calculates error rate change
  - [ ] Triggers revert on threshold breach
  - [ ] Updates proposal status

- [ ] **TODO**: Create `jarvis/scripts/revert-proposal.sh`

  **File**: `jarvis/scripts/revert-proposal.sh`

  **Requirements**:
  - Input: proposal_id
  - Find commit SHA from proposal implementation log
  - Run `git revert <sha>`
  - Re-run provision.py if needed
  - Update proposal status to "reverted"

  **Acceptance Criteria**:
  - [ ] Correctly identifies commit to revert
  - [ ] Clean revert without conflicts
  - [ ] Updates status

### 7.5 Phase 5 Validation

- [ ] **TODO**: End-to-end test
  - Create test proposal (manual)
  - Approve it
  - Run implementation flow
  - Verify PR is created
  - Merge PR manually
  - Verify deploy runs
  - Verify monitoring starts

- [ ] **TODO**: Test rollback
  - Artificially trigger error spike
  - Verify auto-revert works
  - Verify status updates

- [ ] **TODO**: Document discoveries in [Changelog](#10-changelog)

---

## 8. Phase 6: Enhancement Discovery

**Goal**: Weekly scan for improvement opportunities.

### 8.1 Enhancement Scanner

- [ ] **TODO**: Create `jarvis/scheduler/tasks/enhancement_scan.py`

  **File**: `jarvis/scheduler/tasks/enhancement_scan.py`

  **Requirements**:
  - Run weekly analysis via PlannerAgent
  - Scope (stability-focused only):
    - Recurring error patterns not yet addressed
    - Flaky scheduled tasks
    - RAG index staleness
    - Agent prompt drift
  - Output proposals same as self-eval

  **Acceptance Criteria**:
  - [ ] Uses PlannerAgent correctly
  - [ ] Focuses on stability only
  - [ ] Creates valid proposals

- [ ] **TODO**: Add scheduled task
  ```yaml
  enhancement-scan:
    schedule: "0 6 * * 0"  # Sundays at 6 AM
    type: python
    script: /opt/jarvis/scheduler/tasks/enhancement_scan.py
    agent: PlannerAgent
    timeout: 900
    notify_on:
      - error
      - proposal_created
    description: "Weekly scan for stability improvements"
  ```

### 8.2 Phase 6 Validation

- [ ] **TODO**: Test enhancement scan
  - Run manually
  - Verify output format
  - Verify proposals are valid

- [ ] **TODO**: Document discoveries in [Changelog](#10-changelog)

---

## 9. Post-Implementation

### 9.1 Documentation

- [ ] **TODO**: Update CLAUDE.md with self-improvement system commands
- [ ] **TODO**: Create runbook for proposal management
- [ ] **TODO**: Document recovery procedures

### 9.2 Monitoring Setup

- [ ] **TODO**: Create dashboard for proposal metrics
  - Proposals created per week
  - Approval rate
  - Implementation success rate
  - Rollback rate

### 9.3 Tuning

- [ ] **TODO**: Adjust thresholds based on initial operation
  - Error spike threshold (start at 25%)
  - Proposal frequency limits
  - Notification batching windows

---

## 10. Changelog

Track all changes, decisions, and discoveries during implementation.

| Date | Phase | Change | Reason |
|------|-------|--------|--------|
| 2026-01-10 | - | Initial plan created | - |
| 2026-01-11 | Prereq | Installed shellcheck, created backup branch | Setup |
| 2026-01-11 | 1 | Created telemetry/ directory structure | Foundation |
| 2026-01-11 | 1 | Implemented schemas.py with dataclasses (not pydantic) | Zero external deps |
| 2026-01-11 | 1 | Implemented sanitizer.py with comprehensive redaction | Security critical |
| 2026-01-11 | 1 | Implemented collector.py for log parsing | Data collection |
| 2026-01-11 | 1 | Created extract.sh with 30-day cleanup | Automation |
| 2026-01-11 | 1 | Added telemetry-extract scheduled task | Daily at 1 AM |
| 2026-01-11 | 2 | Added EvalAgent to agents.yaml | Stability-focused persona |
| 2026-01-11 | 2 | Created proposals/ directory with templates | Git-based workflow |
| 2026-01-11 | 2 | Implemented self_eval.py task | Analyzes telemetry |
| 2026-01-11 | 3 | Created index-proposals.py script | Auto-generate index |
| 2026-01-11 | 3 | Implemented notify_proposals.py with batching | Alert fatigue prevention |
| 2026-01-11 | 4 | Created policy_test.py with 7 test categories | Blocks dangerous changes |
| 2026-01-11 | 4 | Created validate-branch.sh pipeline | yamllint + shellcheck + policy |
| 2026-01-11 | 5 | Added write_patch, validate_branch, open_pr to Tools Gateway | PR workflow support |
| 2026-01-11 | 5 | Added self-eval and enhancement-scan scheduled tasks | Disabled until ready |

---

## 11. Discovered Issues & Enhancements

Track issues found and enhancement ideas discovered during implementation. These may become future proposals themselves.

### Issues Found

| Date | Phase | Issue | Severity | Resolution |
|------|-------|-------|----------|------------|
| 2026-01-11 | Prereq | pip/pip3 not available on Proxmox host | Low | Used system Python, avoided pydantic dependency |
| 2026-01-11 | Prereq | GitHub CLI not configured | Medium | Deferred - needed for PR creation |
| 2026-01-11 | Prereq | AGiXT stack not deployed to /opt/jarvis yet | Info | Code is ready, will work when deployed |
| 2026-01-11 | 1 | Used dataclasses instead of pydantic | Design | Avoids external dependency, works with Python 3.13 stdlib |

### Enhancement Ideas

| Date | Phase | Idea | Priority | Notes |
|------|-------|------|----------|-------|
| 2026-01-11 | 2 | Add AGiXT API integration to self_eval.py | High | Currently placeholder, needs AGIXT_API_KEY |
| 2026-01-11 | 3 | Add LibreChat command handler for proposal approval | Medium | Currently only notification, no inline approval |
| 2026-01-11 | 5 | Add post-deploy monitoring task | Medium | Auto-revert on error spike |
| 2026-01-11 | 6 | Implement enhancement-scan with weekly telemetry analysis | Low | Phase 6 not yet implemented |

### Deferred Items

Items that were out of scope but should be considered for future phases.

| Item | Reason Deferred | Future Phase |
|------|-----------------|--------------|
| | | |

---

## Appendix A: File Manifest

Complete list of files to be created:

```
jarvis/
├── telemetry/
│   ├── __init__.py
│   ├── schemas.py
│   ├── sanitizer.py
│   ├── collector.py
│   ├── extract.sh
│   └── events/
│       └── .gitkeep
├── proposals/
│   ├── index.md
│   ├── templates/
│   │   ├── bugfix.md
│   │   ├── optimization.md
│   │   └── enhancement.md
│   └── 2026/
│       └── 01/
│           └── .gitkeep
├── tests/
│   ├── __init__.py
│   ├── conftest.py
│   ├── policy_test.py
│   └── syntax_test.py
├── scripts/
│   ├── index-proposals.py
│   ├── validate-branch.sh
│   ├── implement-proposal.py
│   ├── deploy-proposal.sh
│   └── revert-proposal.sh
├── scheduler/
│   └── tasks/
│       ├── self_eval.py
│       ├── notify_proposals.py
│       ├── monitor_deployment.py
│       └── enhancement_scan.py
└── tools-gateway/
    └── proposal_commands.py
```

## Appendix B: Modified Files

Files that need modification:

| File | Changes |
|------|---------|
| `agents/agents.yaml` | Add EvalAgent definition |
| `scheduler/scheduled_tasks.yaml` | Add telemetry-extract, self-eval, notify-*, enhancement-scan |
| `scheduler/crontab` | Add cron entries for new tasks |
| `tools-gateway/main.py` | Add write_patch, validate_branch, open_pr actions |
| `tools-gateway/actions.yaml` | Add staging paths to allowlist |
