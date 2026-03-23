# PlotLens Deploy Reliability Design

**Date:** 2026-03-23
**Status:** Draft
**Repo:** Family-Friendly-Inc/plotlens
**Trigger:** CI deploy timeout — Helm upgrade exceeded 15m due to 5GB worker image re-pull

## Problem Statement

PlotLens deploys to the homelab K3s cluster are unreliable. A deploy that only changed the `word-addin` service caused ALL pods to restart, triggering a 16m+ pull of the 5GB worker image, ephemeral-storage eviction, and a Helm `--atomic` timeout at 15m.

### Root Causes

1. **Unpinned image tags:** All services except the changed one use `:latest` with `imagePullPolicy: Always`, causing unnecessary re-pulls on every deploy
2. **Shared configmap checksum:** 4 deployments (api, gateway, realtime, worker) share a single configmap with a `checksum/config` annotation — any config render change restarts all 4
3. **Oversized worker image:** spaCy NLP models (~500MB) baked into the base image push the worker to ~5GB
4. **Tight timeout:** 15m Helm timeout is insufficient for the worker image pull alone (16m31s observed)

## Design

### Fix 1: Pin Image Tags for All Services

**Goal:** Every deploy uses deterministic, immutable SHA tags for all services. Only services whose image digest actually changed get new pods.

#### CI Workflow Changes (`build-push.yaml`)

Add a **`resolve-tags`** job after `build` and before `deploy`:

```yaml
resolve-tags:
  needs: [build]
  runs-on: [self-hosted, plotlens]
  outputs:
    api-tag: ${{ steps.tags.outputs.api }}
    gateway-tag: ${{ steps.tags.outputs.gateway }}
    worker-tag: ${{ steps.tags.outputs.worker }}
    realtime-tag: ${{ steps.tags.outputs.realtime }}
    frontend-tag: ${{ steps.tags.outputs.frontend }}
    website-tag: ${{ steps.tags.outputs.website }}
    word-addin-tag: ${{ steps.tags.outputs.word-addin }}
  steps:
    - name: Resolve image tags
      id: tags
      run: |
        COMMIT_SHA="${{ github.sha }}"
        SERVICES="api gateway worker realtime frontend website word-addin"
        BUILT='${{ needs.build.outputs.built-services }}'

        for SVC in $SERVICES; do
          REPO="plotlens/plotlens-${SVC}"
          if echo "$BUILT" | grep -qw "$SVC"; then
            # Service was built this run — SHA tag already exists
            echo "${SVC}=${COMMIT_SHA}" >> "$GITHUB_OUTPUT"
          else
            # Service not built — retag :latest with commit SHA
            # Use Harbor API to copy the manifest (no layer re-push)
            # Pin by digest to avoid race conditions between concurrent CI runs
            DIGEST=$(crane digest "harbor.corbello.io/${REPO}:latest" 2>/dev/null || true)
            if [[ -n "$DIGEST" ]]; then
              crane cp "harbor.corbello.io/${REPO}@${DIGEST}" "harbor.corbello.io/${REPO}:${COMMIT_SHA}"
              echo "${SVC}=${COMMIT_SHA}" >> "$GITHUB_OUTPUT"
            else
              echo "::error::No image found for ${REPO}:latest"
              exit 1
            fi
          fi
        done
```

**Requirements:**
- Install `crane` (Google's container registry CLI) on the self-hosted runner, or use Harbor's REST API directly
- The `build` job must output which services were actually built (`built-services`) as a comma-separated list (e.g., `word-addin` or `api,worker,frontend`)
- Harbor credentials must be available to the `resolve-tags` job for `crane` authentication

#### Deploy Step Changes

Update the Helm upgrade command to pass tags for ALL services:

```yaml
helm upgrade plotlens infra/helm/plotlens/ \
  --namespace plotlens \
  --values infra/helm/plotlens/values-production.yaml \
  --install --atomic --cleanup-on-fail \
  --history-max 5 --timeout 25m \
  --set api.image.tag=${{ needs.resolve-tags.outputs.api-tag }} \
  --set gateway.image.tag=${{ needs.resolve-tags.outputs.gateway-tag }} \
  --set worker.image.tag=${{ needs.resolve-tags.outputs.worker-tag }} \
  --set realtime.image.tag=${{ needs.resolve-tags.outputs.realtime-tag }} \
  --set frontend.image.tag=${{ needs.resolve-tags.outputs.frontend-tag }} \
  --set website.image.tag=${{ needs.resolve-tags.outputs.website-tag }} \
  --set wordAddin.image.tag=${{ needs.resolve-tags.outputs.word-addin-tag }}
```

#### Helm Values Changes

In `values.yaml`, for each service's image block:

```yaml
image:
  repository: plotlens-api
  tag: ""  # Must be set by CI — no default
  pullPolicy: IfNotPresent  # SHA tags are immutable
```

Remove `:latest` as a default tag. `IfNotPresent` prevents unnecessary re-pulls since SHA-tagged images are immutable.

### Fix 2: Increase Helm Timeout

**One-line change** in the deploy step of `build-push.yaml`:

```yaml
--timeout 25m \
```

Changed from `15m` to `25m` initially. During Phases 1-2 the worker image is still ~5GB (16m31s observed pull), so 20m leaves insufficient headroom. After Phase 3 reduces image sizes, tune down to 15-20m based on observed deploy times.

### Fix 3: Extract Models from Worker Image + Optimize Build

**Goal:** Reduce the worker image from ~5GB to ~1-1.5GB by extracting spaCy models to shared storage and optimizing the build.

#### Part A: Model Extraction to NFS PVC

**1. Create a PVC for models:**

```yaml
# infra/helm/plotlens/templates/models-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "plotlens.fullname" . }}-models
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 2Gi
```

`ReadWriteMany` allows the seed Job to write models and all worker replicas to mount simultaneously. Workers mount with `readOnly: true` in their volumeMounts.

**2. One-time model seed Job:**

```yaml
# infra/helm/plotlens/templates/model-seed-job.yaml
{{- if .Values.worker.models.seedJob.enabled -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "plotlens.fullname" . }}-model-seed
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: hook-succeeded,before-hook-creation
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: seed
          image: python:3.11-slim
          command:
            - sh
            - -c
            - |
              pip install spacy==3.8.11 --no-cache-dir
              pip install --no-cache-dir --target=/models \
                https://github.com/explosion/spacy-models/releases/download/en_core_web_trf-3.8.0/en_core_web_trf-3.8.0.tar.gz \
                https://github.com/explosion/spacy-models/releases/download/en_core_web_lg-3.8.0/en_core_web_lg-3.8.0.tar.gz
          volumeMounts:
            - name: models
              mountPath: /models
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: {{ include "plotlens.fullname" . }}-models
{{- end }}
```

Runs as a Helm post-install hook. Can also be triggered manually for model updates.

**3. Worker deployment mounts the PVC:**

Add to `worker-deployment.yaml`:

```yaml
env:
  - name: PYTHONPATH
    value: /models:$(PYTHONPATH)
volumeMounts:
  - name: models
    mountPath: /models
    readOnly: true
volumes:
  - name: models
    persistentVolumeClaim:
      claimName: {{ include "plotlens.fullname" . }}-models
```

Models installed via `pip --target=/models` are importable via `PYTHONPATH`. The worker code's existing `spacy.load("en_core_web_trf")` calls work unchanged since spaCy discovers models as installed Python packages.

**Note:** The worker's readiness probe should validate model availability. If the NFS mount is slow or the PVC is not yet bound, the worker will fail to load models. The existing Celery inspect ping probe covers this — if models fail to load, the Celery worker won't start, and the probe will fail.

**4. Update `python-base-spacy` Dockerfile:**

Remove the `spacy download` lines:

```dockerfile
# BEFORE
RUN python -m spacy download en_core_web_trf
RUN python -m spacy download en_core_web_lg

# AFTER
# Models loaded from PVC at runtime via PYTHONPATH=/models
```

**5. Add `ephemeral-storage` resource limits to worker:**

To prevent eviction from image layer unpacking or temp files:

```yaml
resources:
  requests:
    ephemeral-storage: 2Gi
  limits:
    ephemeral-storage: 4Gi
```

#### Part B: Image Optimization

Apply to `python-base-spacy/Dockerfile` and `py/apps/worker/Dockerfile`:

1. **`--no-cache-dir` on all pip installs:**
   ```dockerfile
   RUN pip install --no-cache-dir -r requirements.txt
   ```

2. **Strip bytecode and caches in final stage:**
   ```dockerfile
   RUN find /app -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
       find /app -name '*.pyc' -delete 2>/dev/null; \
       true
   ```

3. **Combine RUN layers** where sequential commands don't benefit from cache separation

4. **Audit runtime dependencies** — Ensure no build-only packages (compilers, headers) leak into the final stage

### Fix 4: Per-Component Configmaps

**Goal:** Each backend service gets its own configmap. Config changes only restart the affected service.

#### New Template Structure

Replace `configmap.yaml` with:

**`_configmap-common.tpl`** — Helper that renders shared keys:

```yaml
{{- define "plotlens.configmap-common" -}}
{{- /* Generic env vars from commonEnv — auto-iterated so new keys are picked up */ -}}
{{- range $key, $value := .Values.commonEnv }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- /* Structured service config — derived from nested values */ -}}
DATABASE_HOST: {{ .Values.database.host | quote }}
DATABASE_PORT: {{ .Values.database.port | quote }}
DATABASE_NAME: {{ .Values.database.name | quote }}
DATABASE_POOL_SIZE: {{ .Values.database.poolSize | quote }}
DATABASE_POOL_OVERFLOW: {{ .Values.database.poolOverflow | quote }}
QDRANT_HOST: {{ .Values.qdrant.host | quote }}
QDRANT_PORT: {{ .Values.qdrant.port | quote }}
QDRANT_URL: {{ printf "http://%s:%v" .Values.qdrant.host .Values.qdrant.port | quote }}
S3_ENDPOINT: {{ .Values.s3.endpoint | quote }}
S3_BUCKET: {{ .Values.s3.bucket | quote }}
S3_USE_SSL: {{ .Values.s3.useSSL | quote }}
{{- end }}
```

**Per-component configmaps** (one file per service):

```yaml
# configmap-api.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "plotlens.fullname" . }}-api-config
  labels:
    {{- include "plotlens.labels" . | nindent 4 }}
    app.kubernetes.io/component: api
data:
  {{- include "plotlens.configmap-common" . | nindent 2 }}
  {{- range $key, $value := .Values.api.env }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
```

Same pattern for `configmap-gateway.yaml`, `configmap-realtime.yaml`, `configmap-worker.yaml`.

#### Deployment Template Updates

Each deployment's annotations and envFrom change:

```yaml
# api-deployment.yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap-api.yaml") . | sha256sum }}

envFrom:
  - configMapRef:
      name: {{ include "plotlens.fullname" . }}-api-config
```

Same pattern for gateway, realtime, worker. Frontend, website, and word-addin remain unchanged.

#### Backward Compatibility

The old `plotlens-config` ConfigMap is removed. Since `envFrom` references are updated in the same Helm release, this is atomic — no transition period needed.

## Changes Summary

| File | Repo | Change |
|------|------|--------|
| `.github/workflows/build-push.yaml` | plotlens | Add `resolve-tags` job, update deploy step, increase timeout to 25m |
| `infra/helm/plotlens/values.yaml` | plotlens | Change default tags to `""`, pullPolicy to `IfNotPresent` |
| `infra/helm/plotlens/values-production.yaml` | plotlens | Same tag/pullPolicy changes |
| `infra/helm/plotlens/templates/configmap.yaml` | plotlens | Remove (replaced by per-component configmaps) |
| `infra/helm/plotlens/templates/_helpers.tpl` | plotlens | Add `plotlens.configmap-common` helper, update `plotlens.envFrom` |
| `infra/helm/plotlens/templates/configmap-api.yaml` | plotlens | New — API-specific configmap |
| `infra/helm/plotlens/templates/configmap-gateway.yaml` | plotlens | New — Gateway-specific configmap |
| `infra/helm/plotlens/templates/configmap-realtime.yaml` | plotlens | New — Realtime-specific configmap |
| `infra/helm/plotlens/templates/configmap-worker.yaml` | plotlens | New — Worker-specific configmap |
| `infra/helm/plotlens/templates/api-deployment.yaml` | plotlens | Update checksum + envFrom to component-specific |
| `infra/helm/plotlens/templates/gateway-deployment.yaml` | plotlens | Update checksum + envFrom to component-specific |
| `infra/helm/plotlens/templates/realtime-deployment.yaml` | plotlens | Update checksum + envFrom to component-specific |
| `infra/helm/plotlens/templates/worker-deployment.yaml` | plotlens | Update checksum + envFrom, add model PVC mount |
| `infra/helm/plotlens/templates/models-pvc.yaml` | plotlens | New — NFS PVC for spaCy models |
| `infra/helm/plotlens/templates/model-seed-job.yaml` | plotlens | New — Helm hook to seed models |
| `docker/python-base-spacy/Dockerfile` | plotlens | Remove `spacy download` commands |
| `py/apps/worker/Dockerfile` | plotlens | Add `--no-cache-dir`, strip bytecode |

## Rollout Strategy

1. **Phase 1:** Fix 2 (timeout increase) + Fix 4 (per-component configmaps) — Low risk, immediate deploy reliability improvement
2. **Phase 2:** Fix 1 (pin image tags) — Requires `crane` on runner, changes CI flow
3. **Phase 3:** Fix 3 (model extraction + image optimization) — Requires NFS PVC setup, model seeding, base image rebuild

## Risk and Rollback

- **Fix 1 (tags):** If `crane` tag fails, the deploy step won't have tags and will fail fast. Rollback: revert to `:latest` defaults
- **Fix 2 (timeout):** Zero risk — strictly more permissive
- **Fix 3 (models):** If PVC mount fails, worker can't load models. Mitigation: worker startup probe (Celery inspect ping) will prevent traffic to broken pods. Rollback: revert Dockerfile to bake models back in and remove PYTHONPATH/PVC mount
- **Fix 4 (configmaps):** Atomic swap in a single Helm release. If something breaks, `helm rollback` restores the old single configmap
