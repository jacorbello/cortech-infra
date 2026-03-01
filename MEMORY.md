# MEMORY.md — Long-Term Memory

## Active Projects

### PlotLens
- **Status:** MVP conditionally ready (82% live-tested, Feb 12); swarm sprint in progress
- **Readiness board:** https://github.com/orgs/Family-Friendly-Inc/projects/1
- **Active issues:** #447-#454 (mvp-readiness label)
- **Batch 1 PRs:** #455-#458 (security headers, linting, API docs, Python test env) — under review
- **Batch 2 queued:** #449 (Jest), #451 (rate limiting), #452 (Projects page), #453 (lockfiles)
- **Swarm workflow:** `memory/swarm-sprint-workflow.md` (worktrees at ~/repos/personal/plotlens-swarm/)
- **Repo:** ~/repos/personal/plotlens (GitHub: Family-Friendly-Inc/plotlens)
- **Stack:** FastAPI + Go gateway, PostgreSQL/pgvector, Redis, Celery, MinIO, Qdrant
- **Key rules:** NO direct schema changes — always use Alembic migrations
- *Historical details:* `memory_search("PlotLens technical details")`

### TLA-Innovation
- **GitHub project board:** https://github.com/orgs/TLA-Innovation/projects/5
- **Daily cron job:** 8:30 AM CST M-F, checks Backlog for issues assigned to jacorbello

## Current Infrastructure

### k3s Cluster Storage (Updated 2026-02-07)
- **NFS backend:** cortech-node3 (192.168.1.114) with 10TB ZFS pool
- **StorageClass:** `nfs-node3` for new workloads needing shared/large storage
- **Migration status:** Existing PVCs still on `local-path`, migration pending
- *Full setup details:* `memory_search("k3s NFS storage")`

## People & Context

### Jeremy
- SCA school (Summit Eagles) — Mindy Murphy sends closure notices
- Uses both `jacorbello@gmail.com` (personal) and `jeremy@familyfriendlyinc.com` (work)

## Current Capabilities
- Browser automation via clawd profile for authenticated web interactions
- Sub-agents for parallelizing design, code fixes, research tasks
- Google Stitch accessible via browser automation (no public API)

*For archived project details and historical context, use memory_search() to find specific information.*