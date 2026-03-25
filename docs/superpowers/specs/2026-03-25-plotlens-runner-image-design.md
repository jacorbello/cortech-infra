# Plotlens ARC v2 Runner: Memory Fix + Custom Image

**Date:** 2026-03-25
**Status:** Approved

## Problem

After migrating to ARC v2 runner scale sets, the plotlens CI "Test Companion" job hangs at the "Install Linux dependencies" step. The job runs `sudo apt-get install` for Tauri system dependencies (`libwebkit2gtk-4.1-dev`, etc.) on the `ghcr.io/actions/actions-runner:latest` image. The runner pod dies mid-install — likely OOMKilled at the current 8Gi memory limit given the combined cost of apt, Rust toolchain, and DinD overhead.

Secondary issue: every CI run wastes 2-5 minutes re-installing these same system packages.

## Out of Scope

- Word Add-in Playwright test failures (code/test issue, not infra)
- Other runner scale sets (jarvis, cortech-infra, etc.) — no Tauri deps needed
- Automated image build pipeline (future enhancement)

## Design

### Phase 1: Immediate Memory Bump

Update `k8s/arc-v2/plotlens-runner-values.yaml` resource limits:

| Resource | Current | New |
|----------|---------|-----|
| `requests.memory` | 2Gi | 3Gi |
| `limits.memory` | 8Gi | 12Gi |

Apply via `helm upgrade plotlens-runner` against the live cluster. Existing running jobs finish on old pods; new pods get the higher limits.

### Phase 2: Custom Runner Image

#### Directory Structure

```
k8s/arc-v2/images/plotlens-runner/
  Containerfile        # extends actions-runner with Tauri deps
  README.md            # build, push, and update instructions
```

#### Containerfile

- Base: `ghcr.io/actions/actions-runner:latest`
- Install Tauri system dependencies via `apt-get` (pulled from the plotlens CI workflow's "Install Linux dependencies" step)
- Clean apt cache to minimize image size
- Tag: `harbor.corbello.io/arc/plotlens-runner:<version>` (e.g., `v1`)

#### Values Update

- Change runner `image` from `ghcr.io/actions/actions-runner:latest` to `harbor.corbello.io/arc/plotlens-runner:<version>`
- Pin to a specific version tag (not `latest`) so rebuilds are intentional
- Validate whether memory limit can return to 8Gi once apt-get step is eliminated

#### README.md

Contents:
- What deps are baked in and why
- Build command: `docker build -t harbor.corbello.io/arc/plotlens-runner:v1 -f Containerfile .`
- Push command: `docker push harbor.corbello.io/arc/plotlens-runner:v1`
- Update workflow: bump base image tag, rebuild, push, update values yaml, helm upgrade
- Reference to the plotlens CI workflow as the source of truth for the dep list

#### Image Hosting

Harbor (`harbor.corbello.io`) — keeps pulls internal (faster, no rate limits), consistent with the self-hosted runner strategy.

## Cluster Context

- Plotlens runners schedule on K3s workers (wrk-1 `core-app`, wrk-2 `compute`)
- Current plotlens runner config: min 3 / max 10 pods, DinD mode, 4 CPU / 8Gi limits
- Other runners (jarvis, cortech-infra) use 1 CPU / 1Gi — much lighter workloads
- Node wrk-3 has 30GB+ free memory; wrk-2 has ~4GB free — 12Gi limit is feasible with scheduling spread
