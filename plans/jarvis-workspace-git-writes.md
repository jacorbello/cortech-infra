# Plan (Updated): Enable Jarvis Git Writes to `jarvis-workspace` (Safe, Audited, Human-Gated)
**Target repo:** `https://github.com/jacorbello/jarvis-workspace.git`
**Goal:** Jarvis can draft + stage + propose changes (docs/plans/code) into this repo via a controlled tool, with strong guardrails.

---

## 0) Why a Dedicated Repo Is the Right Call
Using `jarvis-workspace` as the first write-enabled repo is ideal because:
- It isolates Jarvis-created artifacts from your infrastructure repo
- You can iterate on workflow + guardrails safely
- You can enforce a "no production changes" policy until the system earns trust

---

## 1) Definition of Done
- [ ] Jarvis can **stage** changes (branch + commit) into `jarvis-workspace`
- [ ] Jarvis can **open a PR** (optional in Phase 2, recommended)
- [ ] Jarvis can **not** write anywhere else (no accidental infra edits)
- [ ] Every write is:
  - [ ] allowlisted (repo + paths)
  - [ ] validated (format/lint)
  - [ ] scanned (basic secret detection)
  - [ ] auditable (who/what/why/when)
- [ ] Human approval gates exist for:
  - [ ] staging
  - [ ] PR creation
  - [ ] merge (later, optional)

---

## 2) Repo Layout (Recommended Structure)
Create this once in `jarvis-workspace` so Jarvis has a predictable target:

```
jarvis-workspace/
├── docs/
│   ├── system/
│   ├── architecture/
│   ├── runbooks/
│   └── notes/
├── plans/
│   ├── proposals/
│   ├── roadmaps/
│   └── migrations/
├── code/
│   ├── tools/
│   ├── experiments/
│   └── prototypes/
├── prompts/
│   ├── agents/
│   └── templates/
├── adr/
└── README.md
```

**Allowlisted paths (Phase 1 default):**
- [ ] `docs/**`
- [ ] `plans/**`
- [ ] `prompts/**`
- [ ] `adr/**`

**Optionally allow later (Phase 3+):**
- [ ] `code/**` (only after validation pipeline is solid)

---

## 3) Recommended Architecture
**Best practice:** Git writes happen through **Tools Gateway** (not directly inside AGiXT).

### Flow
1) Jarvis (Router/Writer) generates content + unified diff preview.
2) Jarvis requests approval: "Stage these changes to jarvis-workspace?"
3) Tools Gateway stages to a branch:
   - creates branch
   - writes files
   - commits
   - runs validations
   - returns branch + commit + diff summary
4) Jarvis requests approval: "Open PR?"
5) Tools Gateway opens PR (optional) using GitHub token.
6) Merge remains manual until later.

---

## 4) Security Requirements (Hard Requirements)
### 4.1 No direct git credentials in AGiXT
- [ ] GitHub token lives only in Tools Gateway secrets/env
- [ ] AGiXT never sees it

### 4.2 Use a Fine-Grained GitHub PAT (recommended)
Create a fine-grained token limited to:
- Repo: `jacorbello/jarvis-workspace`
- Permissions:
  - Contents: Read/Write
  - Pull Requests: Read/Write (if using PRs)
  - Metadata: Read
- No org-wide scopes.

### 4.3 Path traversal and sensitive files
- [ ] Reject `..`, absolute paths, symlinks out of repo
- [ ] Deny `.env`, `**/secrets*`, `**/*.key`, `id_rsa*`, anything matching key blocks
- [ ] Secret scanning on content before commit (basic patterns is fine initially)

### 4.4 Approval gates
- [ ] Staging requires explicit "yes"
- [ ] PR creation requires explicit "yes"
- [ ] Merge is manual for now (recommended)

---

## 5) Tools Gateway "Git Tool" Contract
You'll expose these actions to AGiXT as tools.

### 5.1 `POST /actions/git_stage`
Stages changes on a branch, commits, runs validation.

**Request:**
- `repo_id`: `"jarvis-workspace"`
- `base_branch`: `"main"`
- `branch_name`: optional (auto if omitted)
- `changes[]`:
  - `path`
  - `operation`: `create|update|delete`
  - `content` (string; required for create/update)
- `commit_message`: optional
- `metadata`:
  - `request_id`
  - `requested_by`
  - `reason`

**Response:**
- `branch`
- `commit_sha`
- `diff_summary`
- `validation_results`
- `file_manifest`

### 5.2 `POST /actions/git_open_pr` (Phase 2)
Creates a PR for a staged branch.

**Request:**
- `repo_id`, `branch`, `base_branch`
- `title`, `body`
- `request_id`

**Response:**
- `pr_url`, `pr_number`

### 5.3 `GET /actions/git_status` (Optional)
- lists staged branches and recent PRs created by Jarvis

---

## 6) Validation Pipeline (Phase 1 Minimum)
**Minimum required on stage:**
- [ ] YAML: parse check for `*.yml/*.yaml`
- [ ] JSON: parse check for `*.json`
- [ ] Markdown: optional lint (or at least basic formatting checks)
- [ ] "Forbidden content" scan (secrets + private key blocks)

**Phase 2+ (optional):**
- [ ] Prettier/eslint if you enable `code/**`

---

## 7) AGiXT Agent Behavior (Policy)
### 7.1 Jarvis-Router
- Must produce:
  - file list
  - short rationale
  - diff preview (or summary)
  - validation plan
- Must ask: **"Approve staging to jarvis-workspace?"**
- Must not claim changes were written unless Tools Gateway confirms success.

### 7.2 WriterAgent
- Generates:
  - the file contents
  - diff (preferred)
  - commit message suggestion
  - tests/validation steps

### 7.3 Domain agents
- Provide domain content only (marketing plan, contract redlines, code guidance, etc.)
- Router/Writer turns it into repo changes.

---

## 8) Implementation Phases + TODOs

## Phase 1 — Enable Staged Writes (No PRs Yet)
### TODOs (Git + Host)
- [ ] On PCT 121 (or wherever Tools Gateway runs), create a workspace directory:
  - e.g. `/opt/jarvis/git/jarvis-workspace`
- [ ] Clone the repo with a deploy token/PAT (Tools Gateway runtime user):
  - `git clone https://github.com/jacorbello/jarvis-workspace.git`
- [ ] Ensure `main` exists and the repo has the baseline directory structure (Section 2).

### TODOs (Tools Gateway)
- [ ] Add a repo registry config:
  - `repo_id: jarvis-workspace`
  - `path: /opt/jarvis/git/jarvis-workspace`
  - `remote: https://github.com/jacorbello/jarvis-workspace.git`
  - `allow_paths: [docs/**, plans/**, prompts/**, adr/**]`
- [ ] Implement `git_stage` action:
  - branch create
  - apply file changes
  - validate
  - commit
  - return diff summary
- [ ] Add audit logging per request_id (include file list + diff hash).

### TODOs (AGiXT)
- [ ] Add/confirm a single "tool" that calls Tools Gateway `git_stage`
- [ ] Update Jarvis-Router persona:
  - explicitly states it can write only via git_stage and only to jarvis-workspace allowlisted paths
  - always requests approval prior to staging

### Acceptance Criteria
- [ ] Jarvis can stage a new markdown file under `plans/` and you can see the commit on a branch.

---

## Phase 2 — PR Creation
### TODOs (Tools Gateway)
- [ ] Add GitHub fine-grained PAT secret
- [ ] Implement `git_open_pr`
- [ ] Enforce that PR body includes:
  - rationale
  - risk
  - rollback
  - validation output

### Acceptance Criteria
- [ ] Jarvis stages changes → asks approval → opens PR in `jacorbello/jarvis-workspace`.

---

## Phase 3 — Expand Scope to `code/**` (Optional)
### TODOs
- [ ] Add `code/**` to allowlist (only if you want it)
- [ ] Add prettier/eslint/test runners (repo-specific)
- [ ] Block changes if tests fail

### Acceptance Criteria
- [ ] Jarvis can propose code changes via PR with passing checks.

---

## Phase 4 — Optional Merge Automation (Later)
**Recommendation:** keep merges manual until you have weeks of good behavior.
If you later automate:
- [ ] enforce checks passing
- [ ] enforce file scope (no forbidden paths)
- [ ] enforce approval tokens (possibly dual approval for sensitive areas)

---

## 9) Immediate Next TODOs (Do Now)
1) [ ] Initialize repo structure in `jarvis-workspace` (folders + README)
2) [ ] Clone repo onto the Tools Gateway host path: `/opt/jarvis/git/jarvis-workspace`
3) [ ] Add repo registry entry (repo_id + allowlist)
4) [ ] Implement `git_stage` and run a first "Hello World" staged doc
5) [ ] Add PR creation after staging is stable
