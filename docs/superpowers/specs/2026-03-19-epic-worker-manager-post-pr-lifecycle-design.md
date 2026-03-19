# Epic Worker Manager: Post-PR Lifecycle

Extends `epic-worker-manager` with three new phases after PR creation — review handling, CI monitoring, and merge orchestration — so the full epic-to-merge workflow runs from a single `/epic-worker-manager` invocation.

## Context

Today the manager dispatches `epic-worker` agents and produces a phase summary with PR links and a recommended merge order. From there, the user manually orchestrates three steps:

1. Spawn agents to address Copilot PR review feedback
2. Spawn agents to watch CI, fix failures, iterate
3. Merge PRs in the recommended order

This design automates all three as new phases (Steps 7-9) in the manager, using user checkpoints where the action is hard to reverse or benefits from human judgment.

## Design

### Approach: Manager as Full Lifecycle Orchestrator

- `epic-worker` stays unchanged (implementation only)
- `address-pr-review` stays unchanged (used as-is by dispatched agents)
- `epic-worker-manager` gains Steps 7-9 after the existing Step 6 Phase Summary

The manager already tracks all PRs and their overlap relationships from the dispatch phase. Steps 7-9 consume that same data.

### Updated Flow

```
Steps 0-6 (unchanged):
  Sync → Fetch issues → Overlap analysis → Build plan → Confirm → Dispatch → Summary

Step 7: Review Phase (2 rounds)
  ├─ Prompt user + spawn background review-poller (10 min)
  ├─ Round 1: dispatch address-pr-review agent per PR (parallel)
  ├─ Re-request Copilot review on all PRs
  ├─ Prompt user + spawn background review-poller (10 min)
  └─ Round 2: dispatch address-pr-review agent per PR (parallel)

Step 8: CI Watch Phase
  └─ Dispatch CI-watcher agent per PR (parallel)
      └─ gh pr checks --watch → if fail, fix + push → repeat until green or stuck

Step 9: Merge Phase
  ├─ Present merge order + CI status
  ├─ Wait for user approval
  └─ Merge PRs sequentially via gh pr merge
```

### Step 7: Review Phase

#### Input

The PR list from Step 6 — only PRs that were successfully created. Failed implementations are excluded.

#### Review Checkpoint (used for both rounds)

The manager prompts the user and simultaneously spawns a background polling agent:

```
Review round N ready. 4 PRs awaiting Copilot review:
  PR #210 — Add billing endpoint
  PR #211 — Stripe webhook handler
  PR #212 — Add billing tests
  PR #213 — Billing rate limits

Waiting for Copilot reviews. Say "go" when ready,
or I'll auto-check in ~10 minutes.
```

**Background review-poller agent:** Spawned with `run_in_background: true`. Waits 10 minutes, then checks each PR for Copilot reviews via GraphQL:

```bash
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: PR_NUM) {
      reviews(last: 10) {
        nodes { author { login } state submittedAt }
      }
    }
  }
}'
```

If all PRs have Copilot reviews, reports back. If not, retries twice more at 5-minute intervals, then reports partial status. Whichever comes first — user saying "go" or the poller detecting reviews — triggers the round.

#### Round Execution

For each PR with unresolved review threads, dispatch an `address-pr-review` agent:

```
Agent(
  isolation: "worktree",
  run_in_background: true,
  prompt: "Read and execute /root/.claude/skills/address-pr-review/SKILL.md
           for PR #NNN in OWNER/REPO. The repo root is REPO_ROOT."
)
```

PRs with zero unresolved threads are skipped (no agent dispatched).

**Note on `isolation: "worktree"`:** The existing manager (Step 5) warns against using `isolation: "worktree"` for `epic-worker` agents because `epic-worker` manages its own worktree internally and the double-worktree causes permission issues. Steps 7 and 8 use `isolation: "worktree"` intentionally — `address-pr-review` is designed for that execution model, and CI-watcher agents need an isolated workspace for fixes.

#### After Round 1

Re-request Copilot review on all PRs:

```bash
gh api repos/OWNER/REPO/pulls/PR_NUM/requested_reviewers \
  -f 'reviewers[]=copilot' -X POST
```

Report round 1 results, then enter the same checkpoint pattern for round 2.

#### After Round 2

Report results and proceed directly to Step 8 (no user checkpoint).

```
Review phase complete:
  PR #210 — 3 threads resolved (R1), 1 resolved (R2)
  PR #211 — 1 thread resolved (R1), 0 threads (R2)
  PR #212 — No feedback either round
  PR #213 — 2 resolved, 1 pushed back (R1), 1 resolved (R2)

Proceeding to CI watch...
```

### Step 8: CI Watch Phase

Dispatch one CI-watcher agent per PR, all in parallel with `run_in_background: true` and `isolation: "worktree"` (agents need a worktree to fix code if CI fails).

#### CI-Watcher Agent Behavior

1. Run `gh pr checks PR_NUM --watch` to wait for CI to complete
2. If all checks pass: report success, done
3. If any checks fail: read failure logs, diagnose, fix, push, run `gh pr checks PR_NUM --watch` again
4. Repeat until green or the agent determines it's stuck (same failure repeating, fix is beyond scope)
5. Report final status: success, fixed (with details), or failed (with diagnosis)

#### After All Watchers Return

Collect and report:

```
CI Status:
  ✓ PR #210 — All checks passing
  ✓ PR #211 — All checks passing (fixed: lint error on line 42)
  ✓ PR #212 — All checks passing
  ✗ PR #213 — Failing: integration test timeout (agent could not resolve)

3/4 green, 1 needs manual attention
```

PRs with failed CI are excluded from the merge phase and flagged for follow-up.

### Step 9: Merge Phase

#### Present Merge Order

Uses the same merge-order logic from the existing Step 6:

1. Infra/config-only PRs first
2. No-overlap PRs next (smallest diff first)
3. Chain order (earlier batch first within overlap chains)
4. Independent-stack PRs (any relative order)
5. Failed/excluded PRs noted separately

```
All CI green. Ready to merge 3 PRs:

Recommended merge order:
  1. PR #212 — Add billing tests (tests only, no conflicts)
  2. PR #211 — Stripe webhook handler (independent)
  3. PR #210 — Add billing endpoint (billing.py, routes.py)

Excluded:
  PR #213 — CI failing, needs manual attention

Approve to merge in this order, or adjust the sequence.
```

#### On User Approval

Merge sequentially:

```bash
gh pr merge PR_NUM --merge --delete-branch
```

Sequential because later PRs in overlap chains depend on earlier ones being landed. If a merge fails (e.g., conflict from an external commit on main), the manager stops, reports which PR failed and why, and asks the user how to proceed.

### Guardrails (additions to existing list)

- **Never merge without user approval** — the merge checkpoint is mandatory
- **Exclude failed PRs from later phases** — implementation failures skip review, CI failures skip merge
- **2 review rounds is the default** — not configurable for now
- **Background pollers are fire-and-forget** — if the user says "go" first, the poller result is ignored
- **Merge failures halt the sequence** — don't continue merging if one fails, surface to user

### Error Handling (additions to existing table)

| Situation | Action |
|-----------|--------|
| address-pr-review agent fails | Record failure, include PR in round 2 retry |
| PR has no review threads | Skip in that round |
| CI-watcher agent fails (not CI, agent itself) | Report, exclude from merge, flag for manual |
| Merge conflict on a PR | Stop merge sequence, report to user |
| Background poller can't detect reviews after 3 retries | Report partial status, wait for user |
| All PRs excluded (all failed) | Report phase outcome, stop |

### Integration (updated)

**Required skills (used by dispatched agents):**
- **epic-worker** — implementation agents (Steps 0-6, unchanged)
- **address-pr-review** — review-handling agents (Step 7)
- **superpowers:using-git-worktrees** — called by epic-worker and CI-watcher agents

**No changes needed to:**
- `epic-worker` — still only does implementation
- `address-pr-review` — used as-is via agent dispatch

### Arguments (updated)

```
/epic-worker-manager <LABEL> <PHASE> [--dry-run] [--skip-reviews] [--skip-ci]
```

- `--skip-reviews`: Skip Step 7 entirely (useful if PRs don't need Copilot review)
- `--skip-ci`: Skip Step 8, go straight from reviews to merge phase

These flags allow partial runs — e.g., if you already addressed reviews manually and just want CI-watch + merge.

**PR discovery when skipping steps:** When `--skip-reviews` or `--skip-ci` is used, the manager may not have an in-memory PR list from earlier steps. In this case, it re-derives the PR list by querying GitHub for open PRs on branches matching the epic's label/phase pattern, or by looking for PRs whose body contains `Closes #N` referencing issues with the epic label. This ensures the manager can pick up mid-flow without requiring a full run from Step 0.
