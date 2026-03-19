# TTS Platform: Kokoro + Piper Deployment Design

**Date:** 2026-03-19
**Status:** Approved
**Namespace:** `tts`

## Overview

Deploy two TTS services to the K3s cluster as general-purpose homelab infrastructure:

- **Kokoro** (primary) — high-quality OpenAI-compatible TTS API, CPU-only initially with documented GPU migration path
- **Piper** (fallback) — lightweight CPU-only TTS with British English voices, custom image built from official `piper1-gpl` repo

Consumers: Alastar (OpenClaw), n8n automations, various scripts. Accessible from the LAN via NodePort, not exposed to the internet.

## Architecture

### Access Pattern

```
LAN clients (Mac Mini, n8n, Alastar)
  ├── http://192.168.1.90:30881/v1/audio/speech  → Kokoro (OpenAI-compatible)
  └── http://192.168.1.90:30500/                  → Piper (POST with text/voice)
```

No Traefik IngressRoute, no NGINX proxy config. NodePort services only.

### Directory Structure

```
apps/tts/
├── argocd-application.yaml
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── rbac/
│   │   ├── service-account.yaml
│   │   ├── limit-range.yaml
│   │   └── resource-quota.yaml
│   ├── kokoro/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── piper/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── pvc.yaml
│   └── monitoring/           # Future: ServiceMonitor if needed
├── images/
│   └── piper/
│       └── Dockerfile
└── overlays/
    └── production/
        └── kustomization.yaml
```

ArgoCD Application targets `apps/tts/overlays/production`, auto-sync with prune, self-heal, and `CreateNamespace=true`.

## Component Details

### Kokoro (Primary TTS)

| Field | Value |
|-------|-------|
| Image | `ghcr.io/remsky/kokoro-fastapi-cpu:v0.2.4` |
| Replicas | 1 |
| Container port | 8880 |
| NodePort | 30881 |
| Node affinity | `role in [core-app, compute]` |
| CPU request/limit | 500m / 2 |
| Memory request/limit | 1Gi / 2Gi |
| Liveness probe | `GET /docs`, initialDelay 90s, period 30s, failure 3 |
| Readiness probe | `GET /v1/audio/voices`, initialDelay 60s, period 10s, failure 3 |
| Labels | `app.kubernetes.io/part-of: tts-platform` |
| Service account | `tts` |

**API endpoints:**

- `POST /v1/audio/speech` — synthesize text (OpenAI-compatible)
- `GET /v1/audio/voices` — list available voices
- `GET /docs` — Swagger UI
- `GET /web` — built-in web UI

**Supported audio formats:** MP3, WAV, OPUS, FLAC, M4A, PCM

### Piper (Fallback TTS)

| Field | Value |
|-------|-------|
| Image | `harbor.corbello.io/tts/piper:1.0.0` |
| Replicas | 1 |
| Container port | 5000 |
| NodePort | 30500 |
| Node affinity | `role in [core-app, compute]` |
| CPU request/limit | 100m / 500m |
| Memory request/limit | 256Mi / 512Mi |
| Liveness probe | `GET /voices`, initialDelay 15s, period 30s, failure 3 |
| Readiness probe | `GET /voices`, initialDelay 10s, period 10s, failure 3 |
| Labels | `app.kubernetes.io/part-of: tts-platform` |
| Service account | `tts` |

**API endpoints:**

- `POST /` — synthesize text to WAV (`{"text": "...", "voice": "en_GB-aru-medium", "speaker_id": 10}`)
- `GET /voices` — list available voices

**Baked-in voices:**

| Voice | Model | Notes |
|-------|-------|-------|
| `en_GB-aru-medium` | `en_GB-aru-medium.onnx` + `.json` | Multi-speaker, use speaker_id 10 |
| `en_GB-northern_english_male-medium` | `en_GB-northern_english_male-medium.onnx` + `.json` | Single speaker |

Models downloaded from HuggingFace `rhasspy/piper-voices` during image build.

**Extra voices PVC:**

- Name: `piper-voices-extra`
- Size: 1Gi
- Storage class: NFS (`nfs-node3`)
- Access mode: ReadWriteMany
- Mount path: `/models/extra`
- Purpose: drop additional voice models without rebuilding the image; passed to Piper via `--data-dir`

### Piper Dockerfile

Built from the official `OHF-Voice/piper1-gpl` Dockerfile with modifications:

- Base: `python:3.12-slim` runtime
- Install `piper-tts[http]`
- Download the two British English voice models from HuggingFace at build time
- Both voice models placed in `/models/` directory
- Default entrypoint: `python3 -m piper.http_server -m /models/en_GB-aru-medium.onnx --data-dir /models --host 0.0.0.0 --port 5000`
- The `--data-dir /models` flag allows Piper to discover all baked-in voices (both aru and northern_english_male)
- The `/extra-voices` PVC mount provides a second data directory for additional voices added at runtime

**Prerequisites:** Create a `tts` project in Harbor (`harbor.corbello.io`) before the first image push.

Image pushed to Harbor: `harbor.corbello.io/tts/piper:1.0.0`

## RBAC & Resource Quotas

### Service Account

A dedicated `tts` ServiceAccount used by both deployments. No special RBAC bindings needed initially, but follows the established convention from inference and osint namespaces.

### LimitRange

| Field | Value |
|-------|-------|
| Default CPU | 500m |
| Default memory | 512Mi |
| Default request CPU | 100m |
| Default request memory | 128Mi |
| Max CPU | 4 |
| Max memory | 4Gi |

### ResourceQuota

| Resource | Value |
|----------|-------|
| requests.cpu | 4 |
| limits.cpu | 8 |
| requests.memory | 4Gi |
| limits.memory | 8Gi |
| pods | 6 |

Headroom accounts for rolling updates (briefly 2 pods per service) and a potential future third service.

## Monitoring

No ServiceMonitor or Grafana dashboard in the initial deployment. Neither service exposes a `/metrics` endpoint.

Availability monitoring via:
- Kubernetes liveness/readiness probes
- Existing Blackbox Exporter (can probe NodePort endpoints)

## What Is NOT Included (YAGNI)

- GPU scheduling (see migration path below)
- Network policies
- Priority classes
- ServiceMonitor / Grafana dashboards
- Unified TTS gateway / API adapter
- Traefik IngressRoute
- NGINX proxy config (no internet exposure)

## GPU Migration Path for Kokoro

When GPU acceleration is needed, make these changes to the Kokoro deployment:

1. **Image:** swap to `ghcr.io/remsky/kokoro-fastapi-gpu:<version>`
2. **Node selector:** change to `role: gpu-inference`
3. **Tolerations:** add `key: nvidia.com/gpu, operator: Equal, value: "present", effect: NoSchedule`
4. **Runtime class:** add `runtimeClassName: nvidia`
5. **Resource limits:** add `nvidia.com/gpu: "1"`
6. **Resource quota:** add `requests.nvidia.com/gpu: "1"` and `limits.nvidia.com/gpu: "1"` to the namespace quota
7. **Consideration:** vLLM currently uses the single Tesla T4 in the `inference` namespace. Running both simultaneously requires either a second GPU or time-sharing (e.g., scaling one down when the other is active).

## Upstream References

- Kokoro-FastAPI: https://github.com/remsky/Kokoro-FastAPI
- Kokoro Helm/K8s wiki: https://github.com/remsky/Kokoro-FastAPI/wiki/Setup-Kubernetes
- Piper TTS: https://github.com/OHF-Voice/piper1-gpl
- Piper HTTP API: https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/API_HTTP.md
- Piper voices: https://huggingface.co/rhasspy/piper-voices
