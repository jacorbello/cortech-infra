# Full Cutover Plan: LibreChat + AGiXT → Dify (chat.corbello.io) + Console (dify.corbello.io) + MinIO (separate VM)

**Goal:** Replace LibreChat UI + AGiXT orchestration with **self-hosted Dify** while keeping your **Tools Gateway** as the only "hands", adding **MinIO** for durable object storage + document repository, and preserving **unattended agents** (scheduled + event-driven workflows).

## Status

| Phase | Status | Description |
|-------|--------|-------------|
| 0 | COMPLETE | Pre-flight & Freeze |
| 1 | COMPLETE | Deploy MinIO (separate VM) |
| 2 | COMPLETE | Deploy Dify (new CT/VM) |
| 3 | COMPLETE | Point Dify storage at MinIO (S3) |
| 4 | COMPLETE | Rebuild "Jarvis" in Dify (Apps + Workflows + Knowledge) |
| 5 | NOT_STARTED | Document Repository + Continuous Ingestion (MinIO → Dify Knowledge) |
| 6 | NOT_STARTED | Tools Gateway integration |
| 7 | COMPLETE | Outer Reverse Proxy cutover |
| 8 | NOT_STARTED | Cost controls |
| 9 | NOT_STARTED | Decommission AGiXT |

---

## 1) Decisions / Requirements (lock these in)

### URLs
- **WebApp (Chat UI):** `https://chat.corbello.io` → Dify WebApp
- **Console (Admin/Builder):** `https://dify.corbello.io` → Dify Console

### Network / security posture
- Internal/LAN-only access (as requested)
- Public LLM APIs allowed (OpenAI/Anthropic/etc.)
- No direct shell execution from Dify; all actions go through Tools Gateway allowlists/audit

### Storage
- New **MinIO VM** (S3-compatible) for:
  - Dify file storage (uploads, dataset files, etc.) via `STORAGE_TYPE=s3` and `S3_*` env vars.
  - Your "document repository" bucket(s) that your DocSync job ingests into Dify Knowledge datasets.

---

## 2) Phase 0 — Pre-flight & Freeze

### TODOs
- [ ] **Freeze AGiXT**: no new agents/chains; maintenance only.
- [ ] Export/backup current configs (git tag your infra repo).
- [ ] Confirm your outer reverse proxy (PCT 100) can route:
  - `chat.corbello.io`
  - `dify.corbello.io`

### Acceptance
- [ ] You can revert traffic back to LibreChat within minutes (rollback readiness).

---

## 3) Phase 1 — Deploy MinIO (separate VM)

You want MinIO on its own VM. Do that. Keep it boring and reliable.

### 3.1 VM build

#### TODOs
- [ ] Create a VM in Proxmox: `minio-01`
  - 2–4 vCPU, 4–8GB RAM
  - Disk sized to your doc growth (start 500GB+ if you'll store PDFs/specs/code archives)
- [ ] OS: Ubuntu LTS
- [ ] Add a dedicated data mount for MinIO data (ZFS dataset passthrough or an attached disk)

### 3.2 Install method

Pick one (both are common):
- **Option A: systemd service** (classic)
- **Option B: Docker Compose** (fine too; easier upgrades)

Either is OK. The important part is stable storage + credentials + backups.

### 3.3 MinIO base config

#### TODOs
- [ ] Set strong root creds (non-default). (MinIO docs emphasize changing defaults.)
- [ ] Create buckets:
  - `dify-storage` (for Dify's internal file storage)
  - `jarvis-docrepo` (your "source of truth" docs repo)
- [ ] Create MinIO users + access keys:
  - `dify` → access to `dify-storage` only
  - `docsync` → read/write `jarvis-docrepo`
- [ ] Enable versioning on `jarvis-docrepo` (gives rollback on accidental overwrites)
- [ ] Add lifecycle policy (optional): expire old multipart uploads, etc.

### 3.4 Networking / TLS

#### TODOs
- [ ] Decide URLs (internal):
  - `minio.corbello.io` (S3 API)
  - `minio-console.corbello.io` (admin UI)
- [ ] Reverse proxy via PCT 100 (TLS termination), LAN-only ACLs

### Acceptance
- [ ] You can `mc ls` both buckets from a LAN host
- [ ] You can upload/download a test PDF to `jarvis-docrepo`

---

## 4) Phase 2 — Deploy Dify (new CT/VM)

### 4.1 Provision compute

#### TODOs
- [ ] Create a new CT/VM `dify-01` (recommended separate from old Jarvis CT)
  - 4–8 vCPU, 8–16GB RAM, 50–200GB disk
- [ ] Deploy Dify via their self-host Docker Compose instructions and keep the upstream compose + `.env.example` handy (Dify notes the env doc can be outdated; always cross-check).

### 4.2 Set Dify environment URLs (critical)

Set these to prevent auth/CORS headaches:
- [ ] `APP_WEB_URL=https://chat.corbello.io`
- [ ] `CONSOLE_WEB_URL=https://dify.corbello.io`
- [ ] `APP_API_URL=https://chat.corbello.io`
- [ ] `CONSOLE_API_URL=https://dify.corbello.io`
- [ ] `SERVICE_API_URL=https://dify.corbello.io` (pick one and be consistent)
- [ ] CORS:
  - `WEB_API_CORS_ALLOW_ORIGINS=https://chat.corbello.io`
  - `CONSOLE_CORS_ALLOW_ORIGINS=https://dify.corbello.io`
- [ ] Cookies across subdomains:
  - `COOKIE_DOMAIN=corbello.io`
  - `NEXT_PUBLIC_COOKIE_DOMAIN=1`

### 4.3 Optional: change exposed ports (if you don't want host 80/443)
- [ ] Set `EXPOSE_NGINX_PORT` / `EXPOSE_NGINX_SSL_PORT` if needed.

### Acceptance
- [ ] `https://dify.corbello.io` loads Console
- [ ] `https://chat.corbello.io` loads WebApp
- [ ] Login works with no CORS/401 loop

---

## 5) Phase 3 — Point Dify storage at MinIO (S3)

Dify supports S3 storage via `STORAGE_TYPE=s3` and `S3_*` env vars.

### TODOs
- [ ] In Dify `.env`:
  - `STORAGE_TYPE=s3`
  - `S3_ENDPOINT=http(s)://minio.corbello.io`
  - `S3_BUCKET_NAME=dify-storage`
  - `S3_ACCESS_KEY=...` / `S3_SECRET_KEY=...`
  - `S3_REGION=us-east-1` (or whatever you standardize on)
- [ ] Restart Dify containers
- [ ] Validate by uploading a file in Dify and confirming it lands in `dify-storage`

### Acceptance
- [ ] Uploads work
- [ ] No "file not found" issues
- [ ] MinIO shows objects in `dify-storage`

---

## 6) Phase 4 — Rebuild "Jarvis" in Dify (Apps + Workflows + Knowledge)

### 6.1 Workspace / "Projects" layout

#### TODOs
- [ ] Create workspaces (your Projects equivalent):
  - `Jarvis Ops`
  - `Infra`
  - `A2G Tactical`
  - `Legal`
- [ ] Create apps per workspace:
  - **Chat app**: "Jarvis (Chat)"
  - **Workflow app**: "Jarvis Automations"

### 6.2 Knowledge (RAG) datasets

Dify Knowledge datasets can be maintained via API.

#### TODOs
- [ ] Create datasets:
  - `infra-docs`
  - `jarvis-docs`
  - `legal-templates`
  - `a2g-brand-specs`
- [ ] Define chunking defaults (keep it conservative at first; adjust later)

### 6.3 Triggers for unattended agents

Dify has a Trigger start node for workflows that run on schedules or via webhook.

#### TODOs (minimum set)
- [ ] **Daily Digest** workflow:
  - Start: Schedule Trigger (daily)
  - Steps: query logs → summarize → send to Discord/HA
- [ ] **Proposal Review** workflow:
  - Start: Webhook Trigger (Tools Gateway calls it)
  - Steps: format → ask for approval → persist decision
- [ ] **Doc Ingestion** workflow (optional; I prefer external DocSync, see next section)

> Note: Dify's `TRIGGER_URL` is supposed to control webhook callback base URLs.
> But some versions have had issues where TRIGGER_URL is ignored. Treat this as a risk to verify in your build.

### Acceptance
- [ ] Daily digest fires without manual prompting
- [ ] Webhook-trigger workflow fires from a test curl/internal service

---

## 7) Phase 5 — Document Repository + Continuous Ingestion (MinIO → Dify Knowledge)

You want: markdown/pdf/code/specs, continuous ingest, read/write.

### 7.1 Source-of-truth doc repo in MinIO

#### TODOs
- [ ] Define bucket key layout in `jarvis-docrepo`:
  - `infra/...`
  - `jarvis/...`
  - `legal/...`
  - `a2g/...`
- [ ] Decide how files get in there:
  - Git sync (docs in repos)
  - Manual upload (MinIO console)
  - Tools Gateway "write_doc" action (allowlisted paths → upload to MinIO)

### 7.2 DocSync service (recommended)

Make a tiny service that:
- lists objects in MinIO
- diffs vs last-ingested manifest
- uploads/updates docs into Dify datasets via dataset API

#### TODOs
- [ ] Create `docsync` container (separate from Dify)
- [ ] Store a manifest in MinIO: `jarvis-docrepo/.manifest.json`
- [ ] Implement:
  - "new/changed object" detection (etag/mtime)
  - dataset routing rules (prefix → dataset id)
  - retry/backoff

### 7.3 Dify dataset upload wiring

Dify provides dataset API access from the Knowledge UI.

#### TODOs
- [ ] Create a Dify Dataset API key in each workspace (least privilege)
- [ ] Implement upload using Dify's dataset endpoints (validate against your installed Dify version's API docs)

### Acceptance
- [ ] Put a new PDF into `jarvis-docrepo/infra/...`
- [ ] Within N minutes, it appears in Dify dataset and is retrievable in chat with citations

---

## 8) Phase 6 — Tools Gateway integration (keep your security model)

### TODOs
- [ ] Keep Tools Gateway as-is; add Dify callers:
  - `X-API-Key` per workspace/app
  - scope enforcement per endpoint
- [ ] Build these endpoints (minimum):
  - `read_file` (allowlisted)
  - `webhook_allowlisted`
  - `git_stage` + `git_open_pr` for `jarvis-workspace.git`
  - `notify_discord`, `notify_ha`
  - `request_approval` + `record_approval`
- [ ] In Dify workflows, call Tools Gateway using HTTP request nodes (no direct privileges anywhere else)

### Acceptance
- [ ] Dify can:
  - read allowlisted file content
  - write a plan to jarvis-workspace via PR (after approval)
  - send notifications

---

## 9) Phase 7 — Outer Reverse Proxy cutover (the "straight swap")

### TODOs
- [ ] Add NGINX vhosts:
  - `chat.corbello.io` → Dify WebApp upstream
  - `dify.corbello.io` → Dify Console upstream
- [ ] Move LibreChat to `librechat.corbello.io` (temporary)
- [ ] Confirm LAN-only ACL rules (if required)

### Acceptance
- [ ] Users hit `chat.corbello.io` and land in Dify chat UI
- [ ] Admin hits `dify.corbello.io` and manages apps

---

## 10) Phase 8 — Stop the bleeding (cost controls)

### TODOs
- [ ] In Dify: set default model to "cheap" and only escalate on explicit workflow branches.
- [ ] Add "circuit breakers":
  - max tool calls per workflow run
  - max retries on HTTP steps
  - max workflow runtime
- [ ] Add "budget mode" flag in Tools Gateway (if daily spend > threshold, clamp capabilities)

---

## 11) Phase 9 — Decommission AGiXT (only after Dify is stable)

### TODOs
- [ ] Disable AGiXT unattended tasks first (this is where surprise spend happens)
- [ ] Archive AGiXT configs to `jarvis-workspace`
- [ ] After 2–4 weeks stable:
  - remove AGiXT containers/volumes
  - remove AGiXT endpoints from proxy

### Rollback plan
- If Dify breaks: flip `chat.corbello.io` back to LibreChat upstream and you're live again.

---

## Quick "Build Order" (what I'd do first)

1) MinIO VM + buckets + creds
2) Dify deploy (parallel) + correct URL/CORS/cookie env
3) Dify `STORAGE_TYPE=s3` pointing to MinIO
4) Create workspaces/apps + 1 dataset
5) DocSync minimal (MinIO → Dify dataset)
6) Tools Gateway endpoints + one workflow with Schedule Trigger
7) Proxy cutover of `chat.corbello.io` to Dify

---

## Container Info

| Component | VMID | Type | IP | Node | Specs |
|-----------|------|------|-----|------|-------|
| MinIO | 123 | CT | 192.168.1.118 | cortech | 4 vCPU, 8GB RAM, 500GB disk |
| Dify | 124 | CT | 192.168.1.119 | cortech | 8 vCPU, 16GB RAM, 100GB disk |

## Service Accounts (stored securely, not in repo)

### MinIO Root
- User: `minio-admin`
- Console: `http://192.168.1.118:9001`

### MinIO Service Accounts
| Service | Bucket | Access Key |
|---------|--------|------------|
| Dify | dify-storage | 4O865CF3W09KL5JGMU89 |
| DocSync | jarvis-docrepo | LGAM2QDJY0K1EZVDJ6XZ |

*Secret keys stored in respective service .env files*

---

## Changelog

| Date | Phase | Change |
|------|-------|--------|
| 2026-01-12 | 0 | Initial cutover plan created |
