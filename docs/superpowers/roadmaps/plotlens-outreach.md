# PlotLens Outreach — Living Roadmap

**Last updated:** 2026-05-20 (Reddit deferred to Phase 2.1 mid-T24)

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
- Reddit original posts to r/PlotLens: originally planned as Postiz-automated. **Deferred to Phase 2.1+** during T24 — Reddit's late-2024 Responsible Builder Policy gate makes new OAuth app creation impractical, and Devvit (Reddit's replacement developer platform) doesn't fit a Postiz-style scheduler. Manual posting via Reddit UI is the Phase 2 path.

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

- **Reddit / r/PlotLens automation** — deferred to Phase 2.1+ during T24. Reddit's Responsible Builder Policy gate + Devvit platform shift make a Postiz OAuth integration impractical. Existing n8n Reddit app credentials weren't retrievable for reuse. Manual posting via Reddit UI remains the path; revisit if Reddit relaxes restrictions or Postiz adds Devvit support.
- **X (Twitter) channel** — Phase 2.1, blocked on Developer Account approval (typical 1-7 days but unpredictable).
- **LinkedIn channel** — Phase 2.1, blocked on Marketing Developer Platform approval (1-2 weeks).
- **n8n pure-JS SHA-256 audit** — Phase 2.1 follow-up. T21 discovered n8n's Code-node SHA-256 produces different digests than Postgres's `sha256()` for identical input. Workflow B/C/D are internally consistent (all use the JS impl), so Phase 2 is safe — but worth a code review to confirm correctness and rule out encoding/padding bug.
- **Approval row 42 hash mismatch** — Phase 2.1 investigation. T20 discovered approval 42's `approved_content_hash` doesn't match what Workflow D's recompute produces from the linked draft. Probably a `destination`/`post_type` divergence between Workflow B's draft hash and Workflow C's approval hash; root cause needed.

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
