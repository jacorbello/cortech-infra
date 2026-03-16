# Ollama to vLLM Migration Design

**Date:** 2026-03-16
**Status:** Draft
**Author:** Claude + Jacob Corbello

---

## 1. Overview

Migrate the GPU inference workload from Ollama (VM 205) to vLLM running as a Kubernetes-native pod on a new dedicated GPU worker node. This centralizes inference in a shared `inference` namespace, improves throughput under concurrent load, and provides an OpenAI-compatible API for all consumers.

### Goals

- Replace Ollama with vLLM for LLM inference (Llama 3.2 3B)
- Run vLLM as a K8s pod with proper GPU resource scheduling
- Create a shared `inference` namespace accessible by `osint`, `jarvis`, and `plotlens`
- Architect for co-serving an embedding model (`nomic-embed-text`) alongside the LLM
- Decommission VM 205 after validation

### Non-Goals

- Changing the Llama 3.2 3B model itself (same weights, same quality)
- Migrating cloud-based OpenAI embedding usage — that stays as-is
- Multi-GPU or tensor-parallel setups (single T4)

---

## 2. Current State

### VM 205 (Ollama)

- **Host:** cortech-node3 (192.168.1.114, 96 CPU, 566 GiB RAM)
- **VM IP:** 192.168.1.96
- **GPU:** NVIDIA Tesla T4 (16GB VRAM), PCI passthrough at `0000:3b:00.0`
- **VM config:** q35/OVMF, 8 cores, 64GB RAM, 100GB disk
- **Models:** Llama 3.2 3B (primary), Llama 3.1 8B
- **API:** Ollama-specific at port 11434 (`/api/generate`)
- **Performance:** ~580 tok/s prompt eval, ~73 tok/s generation

### Consumers

The OSINT platform is the sole consumer, connecting via a K8s ClusterIP service with manual Endpoints:

- **K8s Service:** `ollama.osint.svc.cluster.local` → Endpoints point to `192.168.1.114:11434` (cortech-node3 host IP, not the VM IP at `.96` — Ollama binds to `0.0.0.0:11434` inside the VM, and traffic routes via the Proxmox bridge network)
- **Deployments using it:** osint-core, osint-worker, osint-beat
- **Env var:** `OSINT_OLLAMA_URL=http://ollama:11434`
- **API calls:** `POST /api/generate` with `{"model": "llama3.2:3b", "prompt": "...", "stream": false}`
- **Fallback:** Jinja2 template when Ollama/node3 is offline

### VM 206 (k3s-wrk-3)

- **Also on cortech-node3**, 48 cores, 192GB RAM
- **No GPU passthrough** — no `hostpci0`, no q35/OVMF
- **Role:** Ephemeral K3s worker, tainted `NoSchedule`, label `role: batch-compute`
- **Status:** Running

---

## 3. Architecture Decision: Shared `inference` Namespace

**Decision:** Deploy vLLM in a new `inference` namespace, not within `osint`.

**Rationale:**
- GPU workloads are centralized and independently managed
- Any namespace can consume the inference API via cross-namespace DNS
- Matches the existing shared-infrastructure pattern (Postgres in LXC 114, Redis in LXC 116)
- Scales to multiple models (LLM + embeddings) in one namespace
- Clean separation: inference infrastructure vs. application logic

**Alternatives considered:**
- **vLLM in `osint` namespace:** Ties GPU to a single tenant. Other consumers (Jarvis, PlotLens) would need cross-namespace access or duplicate deployments.
- **vLLM Production Stack Helm chart:** Over-engineered for single-GPU homelab. Designed for multi-node GPU clusters.

---

## 4. Architecture Decision: New VM vs. Modify VM 206

**Decision:** Create a new VM 207 (`k3s-wrk-4`) purpose-built for GPU inference, rather than modifying VM 206.

**Rationale:**
- VM 206 lacks q35/OVMF (required for PCIe passthrough) — changing this on a running K3s node risks breaking boot
- VM 206 is an active cluster member doing batch compute — disrupting it affects the cluster
- A new VM can be built from scratch with the correct firmware, drivers, and configuration
- Allows parallel testing: VM 205 (Ollama) and VM 207 (vLLM) can run side-by-side during validation
- cortech-node3 has ample resources (96 CPU, 566 GiB RAM) to host both

---

## 5. New VM 207 (k3s-wrk-4)

### Proxmox Configuration

| Setting | Value |
|---------|-------|
| VM ID | 207 |
| Name | k3s-wrk-4 |
| IP | 192.168.1.98/24 |
| Gateway | 192.168.1.1 |
| Machine | q35 |
| BIOS | OVMF |
| CPU | 16 cores, type: host |
| Memory | 32768 MiB (32 GB) |
| Disk | 100GB on storage-pool |
| GPU | `hostpci0: 0000:3b:00.0,pcie=1,rombar=0,x-vga=0` |
| Network | virtio on vmbr0 |
| OS | Ubuntu 22.04 LTS (or matching existing K3s nodes) |
| Cloud-init user | k3s |

### Software Stack (installed on VM 207)

1. **NVIDIA drivers** — `nvidia-driver-550-server` (or latest stable for T4)
2. **NVIDIA Container Toolkit** — configures containerd (K3s runtime) for GPU access
3. **K3s agent** — joins cluster via `k3s agent --server https://192.168.1.90:6443 --token <token>`

### K3s Node Configuration

- **Labels:** `role: gpu-inference`, `gpu: tesla-t4`, `node-type: worker`
- **Taint:** `nvidia.com/gpu=present:NoSchedule`

### NVIDIA Device Plugin

Deploy as a DaemonSet in `kube-system` with nodeSelector `gpu: tesla-t4`:

- Image: `nvcr.io/nvidia/k8s-device-plugin:v0.17.0` (or latest)
- Advertises `nvidia.com/gpu: 1` to the K8s scheduler
- Manifest location: `k8s/kube-system/nvidia-device-plugin.yaml`

### Verification

After setup, `kubectl describe node k3s-wrk-4` should show:

```
Allocatable:
  nvidia.com/gpu: 1
```

---

## 6. Namespace & RBAC

### Directory Structure

```
apps/inference/
├── argocd-application.yaml
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── rbac/
│   │   ├── service-account.yaml
│   │   ├── resource-quota.yaml
│   │   ├── limit-range.yaml
│   │   └── priority-classes.yaml
│   ├── network-policies/
│   │   └── default-deny.yaml
│   ├── monitoring/
│   │   └── service-monitor.yaml
│   └── vllm/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── pvc.yaml
└── overlays/
    └── production/
        └── kustomization.yaml
```

### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: inference
  labels:
    app.kubernetes.io/part-of: inference-platform
```

### Resource Quota

- GPU: `requests.nvidia.com/gpu: 1`, `limits.nvidia.com/gpu: 1`
- Memory: 20Gi (accounts for vLLM 8Gi + future embedding model ~8Gi + overhead)
- CPU: 16 cores

### Priority Class

- `inference-gpu` at value 200 (higher than `osint-core` at 100 — GPU workloads are expensive to restart and take 2+ minutes to load models)

### Network Policy

Default deny all ingress, with explicit allow rules using `namespaceSelector.matchLabels` on `kubernetes.io/metadata.name` (auto-applied by K3s v1.34):

- Allow ingress on port 8000 from namespaces: `osint`, `jarvis`, `plotlens`
- Allow ingress on port 8000 from namespace: `observability` (Prometheus scraping `/metrics`)
- Allow intra-namespace traffic from namespace: `inference`

### ArgoCD Application

Standard ArgoCD Application pointing at `apps/inference/overlays/production`, same pattern as the OSINT app (`apps/osint/overlays/production`). Auto-sync enabled with prune.

---

## 7. vLLM Deployment

### Deployment Spec

- **Image:** `vllm/vllm-openai:<pinned-tag>` — look up the latest stable release tag at deploy time (do not use `latest`)
- **Command:**
  ```
  vllm serve meta-llama/Llama-3.2-3B-Instruct \
    --dtype float16 \
    --max-model-len 8192 \
    --gpu-memory-utilization 0.85 \
    --port 8000
  ```
- **Key flags:**
  - `--dtype float16`: T4 supports FP16 natively (Tensor Cores)
  - `--max-model-len 8192`: Generous context window, fits in T4 VRAM with 3B model
  - `--gpu-memory-utilization 0.85`: Reserves ~2.4GB for future embedding model co-serving
- **Resources:**
  - Requests: 2 CPU, 4Gi memory, 1 `nvidia.com/gpu`
  - Limits: 4 CPU, 8Gi memory, 1 `nvidia.com/gpu`
- **Tolerations:** `nvidia.com/gpu=present:NoSchedule`
- **Node selector:** `role: gpu-inference`
- **Replicas:** 1 (single GPU)

### Volumes

- **PVC (50Gi, `storageClassName: nfs-node3`):** Mounted at `/root/.cache/huggingface` — persists model weights across pod restarts. Llama 3.2 3B is ~6GB, leaves room for embedding model. Uses the same NFS storageclass as OSINT's Qdrant PVC.
- **emptyDir (Memory, 2Gi):** Mounted at `/dev/shm` — shared memory for tensor operations.

### Health Probes

- **Liveness:** `GET /health` on port 8000, `initialDelaySeconds: 120`, `periodSeconds: 10`
- **Readiness:** `GET /health` on port 8000, `initialDelaySeconds: 120`, `periodSeconds: 5`
- Initial delay is high because model loading from HuggingFace cache takes time on first boot.

### Secrets

- `hf-token-secret` in `inference` namespace — HuggingFace token for gated model access
- Stored via SOPS/Infisical (per repo conventions — never committed in plaintext)
- **Important:** The HuggingFace account associated with this token must have accepted Meta's Llama 3.2 license agreement at https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct
- Env var in deployment: `HF_TOKEN` sourced from `secretKeyRef` to `hf-token-secret`

### Service

- **Type:** ClusterIP
- **Port:** 8000
- **DNS:** `vllm.inference.svc.cluster.local`
- All consumers access via this DNS name

---

## 8. OSINT Application Changes

### Infrastructure Changes (this repo)

**1. Environment variable update in all three deployments (osint-core, osint-worker, osint-beat):**

Replace:
```yaml
- name: OSINT_OLLAMA_URL
  value: "http://ollama:11434"
```

With:
```yaml
- name: OSINT_VLLM_URL
  value: "http://vllm.inference.svc.cluster.local:8000"
- name: OSINT_LLM_MODEL
  value: "meta-llama/Llama-3.2-3B-Instruct"
```

**2. Remove Ollama external service:**

Delete `apps/osint/base/external-services/ollama.yaml` and its reference in `apps/osint/base/kustomization.yaml`.

### Application Code Changes (osint-core repo, separate from this repo)

**API client migration in `brief_generator.py` and `nlp_enrich.py`:**

From Ollama API:
```python
POST {ollama_url}/api/generate
{"model": "llama3.2:3b", "prompt": "...", "stream": false}
```

To OpenAI-compatible API:
```python
POST {vllm_url}/v1/chat/completions
{
  "model": "meta-llama/Llama-3.2-3B-Instruct",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "stream": false
}
```

The Jinja2 fallback pattern remains unchanged — it triggers on vLLM unavailability instead of Ollama unavailability.

### Embedding Path (Future)

When ready to self-host embeddings:
- Add `nomic-embed-text` as a second model to vLLM (or a second vLLM deployment in the same namespace)
- OSINT app's embedding provider config points to `vllm.inference.svc.cluster.local:8000` using `/v1/embeddings`
- No infrastructure changes needed — just app-side config
- Qdrant dimensions for `nomic-embed-text` are already defined in the application

---

## 9. Cutover & Rollback Strategy

### Phase 1: Parallel Running

1. VM 205 (Ollama) stays running and serving traffic
2. VM 207 created, joins K3s cluster, GPU verified
3. vLLM deployed to `inference` namespace
4. Validate health: `curl http://vllm.inference.svc.cluster.local:8000/health`
5. Manual test requests against `/v1/chat/completions` to confirm output quality

### Phase 2: OSINT Cutover

1. Deploy application code changes (new OpenAI-compatible API client)
2. Update K8s manifests in this repo (env var swap, remove ollama external service)
3. ArgoCD syncs the changes
4. Monitor: confirm briefs generating, check latency via Grafana, watch for Jinja2 fallback triggers

### Phase 3: Validation Period (1-2 weeks)

Both VM 205 and VM 207 remain running. Rollback procedure:

1. Revert env vars in manifests back to `OSINT_OLLAMA_URL`
2. Revert app code to Ollama API client
3. Re-add `apps/osint/base/external-services/ollama.yaml`
4. ArgoCD syncs — back to Ollama in minutes

This works because VM 205 hasn't been touched.

### Phase 4: Decommission

1. Shut down VM 205: `qm stop 205`
2. Remove VM 205 from Proxmox (or archive config)
3. Run `make inventory` to update auto-generated docs
4. Update CLAUDE.md architecture tables

---

## 10. Observability

### Prometheus Metrics

vLLM exposes metrics at `/metrics` natively. A ServiceMonitor (`apps/inference/base/monitoring/service-monitor.yaml`) scrapes this endpoint. Key metrics:

- `vllm_request_latency_seconds` — end-to-end request latency
- `vllm_num_requests_running` — current concurrent requests
- `vllm_num_requests_waiting` — queued requests
- `vllm_gpu_cache_usage_perc` — KV cache utilization
- `vllm_avg_generation_throughput_toks_per_s` — tokens per second

Note: vLLM uses underscores (not colons) in metric names. Verify exact names against the deployed version.

### Grafana Dashboard

New ConfigMap in `k8s/observability/dashboards/applications/vllm-inference.yaml` with label `grafana_dashboard: "1"` for sidecar auto-discovery (matching the existing dashboard location pattern under `applications/`). Panels:

- Request throughput (tok/s)
- Request latency (P50, P95, P99)
- GPU memory utilization
- KV cache usage
- Queue depth
- Model load status

### Alerting

Alert rule via Prometheus/Alertmanager:
- vLLM health check fails for >2 minutes → Gotify notification

---

## 11. Expected Performance Improvements

### Throughput & Latency (Llama 3.2 3B on Tesla T4)

| Metric | Ollama (current) | vLLM (projected) | Why |
|--------|-----------------|-------------------|-----|
| Single-request generation | ~73 tok/s | ~80-85 tok/s | Optimized CUDA kernels, flash attention |
| 5 concurrent requests | ~73 tok/s total (serialized) | ~350-400 tok/s aggregate | Continuous batching |
| 10 concurrent requests | Queued, high latency | ~500+ tok/s aggregate | PagedAttention scales with concurrency |
| Time to first token | ~50-100ms | ~10-30ms | Paged prefill, no static allocation |
| P99 latency (under load) | ~670ms+ | ~80ms | Dynamic memory vs. static allocation |

### Resource Efficiency

| Metric | Ollama | vLLM | Impact |
|--------|--------|------|--------|
| VRAM for 3B model | ~3-4GB static | ~2-3GB + dynamic KV cache | Room for embedding model |
| Max context window | Default 2K-4K | 8192 (configurable higher) | Longer brief context payloads |
| Concurrent handling | Sequential | Parallel batching | Workers stop blocking each other |
| Model loading | Per-request warm-up | Always loaded, paged | Consistent latency |

### Key Takeaway

The primary win is **concurrent throughput**. When multiple OSINT Celery workers hit inference simultaneously, vLLM's continuous batching serves them in parallel instead of queuing. This directly reduces the alert-to-brief pipeline latency. Single-request speed improves modestly (~13%).

---

## 12. Files Changed (This Repo)

### New Files

| File | Purpose |
|------|---------|
| `apps/inference/argocd-application.yaml` | ArgoCD app for inference namespace |
| `apps/inference/base/namespace.yaml` | Namespace definition |
| `apps/inference/base/kustomization.yaml` | Kustomize base |
| `apps/inference/base/rbac/service-account.yaml` | vLLM service account |
| `apps/inference/base/rbac/resource-quota.yaml` | GPU/memory/CPU quotas |
| `apps/inference/base/rbac/limit-range.yaml` | Default container limits |
| `apps/inference/base/rbac/priority-classes.yaml` | Inference GPU priority class |
| `apps/inference/base/network-policies/default-deny.yaml` | Ingress rules (osint, jarvis, plotlens, observability) |
| `apps/inference/base/monitoring/service-monitor.yaml` | Prometheus ServiceMonitor for vLLM metrics |
| `apps/inference/base/vllm/deployment.yaml` | vLLM Deployment |
| `apps/inference/base/vllm/service.yaml` | ClusterIP Service |
| `apps/inference/base/vllm/pvc.yaml` | HuggingFace cache PVC (nfs-node3) |
| `apps/inference/overlays/production/kustomization.yaml` | Production overlay |
| `k8s/kube-system/nvidia-device-plugin.yaml` | GPU device plugin DaemonSet |
| `k8s/observability/dashboards/applications/vllm-inference.yaml` | Grafana dashboard ConfigMap |

### Modified Files

| File | Change |
|------|--------|
| `apps/osint/base/osint-core/deployment.yaml` | Replace `OSINT_OLLAMA_URL` with `OSINT_VLLM_URL` + `OSINT_LLM_MODEL` |
| `apps/osint/base/osint-worker/deployment.yaml` | Same env var change |
| `apps/osint/base/osint-beat/deployment.yaml` | Same env var change |
| `apps/osint/base/kustomization.yaml` | Remove ollama external service reference |

### Deleted Files

| File | Reason |
|------|--------|
| `apps/osint/base/external-services/ollama.yaml` | Replaced by vLLM in inference namespace |

---

## 13. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| VM 207 q35/OVMF boot issues | Low | Medium | New VM, no existing state to break |
| NVIDIA driver compatibility | Low | High | Use well-tested driver version (550-server) |
| vLLM model loading slow on first pull | Medium | Low | PVC persists cache; only slow on first deploy |
| API response format differences | Medium | Medium | Test thoroughly in Phase 1 before cutover |
| cortech-node3 offline | Known | Medium | Jinja2 fallback unchanged — same resilience |
| GPU PCI device conflict (both VMs) | Low | High | VM 205 must be stopped before VM 207 gets GPU; only one VM can hold the passthrough at a time during parallel phase, resolved by stopping 205 first |
| Egress for model download | Low | Low | vLLM needs egress to huggingface.co on first startup to pull model weights. PVC cache eliminates this need on subsequent restarts. No egress network policy restriction needed (default deny is ingress-only). |
| Shared-fate: node3 offline takes both wrk-3 and wrk-4 | Known | Medium | Same risk as today. Jinja2 fallback covers inference. Batch compute (wrk-3) and inference (wrk-4) both go down if node3 is offline. |

**Note on GPU sharing during parallel phase:** The T4 can only be passed through to one VM at a time. During Phase 1, we must stop VM 205 before starting VM 207 with the GPU. This means there's a brief window where Ollama is unavailable — the Jinja2 fallback covers this. Once VM 207 is up and vLLM is verified, VM 205 can be restarted *without* the GPU passthrough if we want it running for non-GPU purposes, or simply left stopped.
