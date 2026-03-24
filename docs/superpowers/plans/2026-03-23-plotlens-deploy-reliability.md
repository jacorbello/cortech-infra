# PlotLens Deploy Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PlotLens deploys reliable by pinning image tags, splitting configmaps, extracting models from the worker image, and increasing the Helm timeout.

**Architecture:** Four targeted fixes across the CI workflow (`build-push.yaml`), Helm chart templates, Helm values, and Docker images. Changes are phased: Phase 1 (low risk, immediate relief), Phase 2 (CI flow changes), Phase 3 (image architecture changes).

**Tech Stack:** GitHub Actions, Helm 3, Kubernetes manifests (YAML), Docker, crane (container registry CLI), NFS CSI

**Spec:** `docs/superpowers/specs/2026-03-23-plotlens-deploy-reliability-design.md` (in cortech-infra repo)

**Target repo:** `Family-Friendly-Inc/plotlens` (clone required — all changes are in this repo)

---

## File Map

### Phase 1 — Timeout + Per-Component Configmaps

| Action | File | Purpose |
|--------|------|---------|
| Modify | `.github/workflows/build-push.yaml` | Change `--timeout 15m` to `--timeout 25m` |
| Delete | `infra/helm/plotlens/templates/configmap.yaml` | Replace with per-component configmaps |
| Modify | `infra/helm/plotlens/templates/_helpers.tpl` | Add `plotlens.configmap-common` helper, update `plotlens.envFrom` per component |
| Create | `infra/helm/plotlens/templates/configmap-api.yaml` | API-specific configmap |
| Create | `infra/helm/plotlens/templates/configmap-gateway.yaml` | Gateway-specific configmap |
| Create | `infra/helm/plotlens/templates/configmap-realtime.yaml` | Realtime-specific configmap |
| Create | `infra/helm/plotlens/templates/configmap-worker.yaml` | Worker-specific configmap |
| Modify | `infra/helm/plotlens/templates/api-deployment.yaml` | Update checksum + envFrom |
| Modify | `infra/helm/plotlens/templates/gateway-deployment.yaml` | Update checksum + envFrom |
| Modify | `infra/helm/plotlens/templates/realtime-deployment.yaml` | Update checksum + envFrom |
| Modify | `infra/helm/plotlens/templates/worker-deployment.yaml` | Update checksum + envFrom |

### Phase 2 — Pin Image Tags

| Action | File | Purpose |
|--------|------|---------|
| Modify | `.github/workflows/build-push.yaml` | Add `resolve-tags` job, update deploy step, add `built-services` output to build job |
| Modify | `infra/helm/plotlens/values.yaml` | Change default tags to `""`, pullPolicy to `IfNotPresent` |
| Modify | `infra/helm/plotlens/values-production.yaml` | Same tag/pullPolicy changes |

### Phase 3 — Model Extraction + Image Optimization

| Action | File | Purpose |
|--------|------|---------|
| Create | `infra/helm/plotlens/templates/models-pvc.yaml` | NFS PVC for spaCy models |
| Create | `infra/helm/plotlens/templates/model-seed-job.yaml` | Helm hook Job to download models |
| Modify | `infra/helm/plotlens/templates/worker-deployment.yaml` | Add PVC mount, PYTHONPATH, ephemeral-storage limits |
| Modify | `infra/helm/plotlens/values.yaml` | Add `worker.models` config block |
| Modify | `infra/helm/plotlens/values-production.yaml` | Enable model seed job, set ephemeral-storage |
| Modify | `docker/python-base-spacy/Dockerfile` | Remove `spacy download` commands |
| Modify | `py/apps/worker/Dockerfile` | Add `--no-cache-dir`, strip bytecode |

---

## Phase 1: Timeout + Per-Component Configmaps

### Task 1: Clone repo and create feature branch

- [ ] **Step 1: Clone the plotlens repo**

```bash
cd /root/repos/personal
git clone git@github.com:Family-Friendly-Inc/plotlens.git plotlens-deploy-fix 2>/dev/null || { cd plotlens-deploy-fix && git pull; }
cd /root/repos/personal/plotlens-deploy-fix
```

- [ ] **Step 2: Create feature branch**

```bash
git checkout -b fix/deploy-reliability main
```

- [ ] **Step 3: Verify key files exist**

```bash
ls -la .github/workflows/build-push.yaml \
       infra/helm/plotlens/templates/configmap.yaml \
       infra/helm/plotlens/templates/_helpers.tpl \
       infra/helm/plotlens/templates/api-deployment.yaml \
       infra/helm/plotlens/templates/gateway-deployment.yaml \
       infra/helm/plotlens/templates/realtime-deployment.yaml \
       infra/helm/plotlens/templates/worker-deployment.yaml
```

Expected: all files exist.

### Task 2: Increase Helm timeout to 25m

**Files:**
- Modify: `.github/workflows/build-push.yaml`

- [ ] **Step 1: Find the current timeout value**

```bash
grep -n 'timeout 15m' .github/workflows/build-push.yaml
```

Expected: one or more matches showing `--timeout 15m`.

- [ ] **Step 2: Replace 15m with 25m**

Change every occurrence of `--timeout 15m` to `--timeout 25m` in `.github/workflows/build-push.yaml`.

- [ ] **Step 3: Verify the change**

```bash
grep -n 'timeout' .github/workflows/build-push.yaml
```

Expected: all timeout references now show `25m`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-push.yaml
git commit -m "fix: increase Helm deploy timeout from 15m to 25m

Worker image pull takes 16m31s — 15m timeout guaranteed failure.
25m provides headroom while image size is addressed separately."
```

### Task 3: Add configmap-common helper to _helpers.tpl

**Files:**
- Modify: `infra/helm/plotlens/templates/_helpers.tpl`

- [ ] **Step 1: Read the current `plotlens.envFrom` helper**

Find the `plotlens.envFrom` definition in `_helpers.tpl`. It currently references the shared configmap name `{{ include "plotlens.fullname" . }}-config`.

- [ ] **Step 2: Add the `plotlens.configmap-common` helper**

Append this new helper definition at the end of `_helpers.tpl` (before any final newlines):

```yaml
{{/*
Common configmap data shared across all backend services.
Generic env vars from commonEnv are auto-iterated; structured service
config (database, qdrant, s3) is rendered from nested values.
*/}}
{{- define "plotlens.configmap-common" -}}
{{- range $key, $value := .Values.commonEnv }}
{{ $key }}: {{ $value | quote }}
{{- end }}
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

- [ ] **Step 3: Update the `plotlens.envFrom` helper**

The current `plotlens.envFrom` helper references a single configmap. It needs to accept a component parameter. Replace the existing `plotlens.envFrom` definition with:

```yaml
{{/*
envFrom block — references the per-component configmap.
Usage: {{ include "plotlens.envFrom" (dict "root" . "component" "api") }}
*/}}
{{- define "plotlens.envFrom" -}}
- configMapRef:
    name: {{ include "plotlens.fullname" .root }}-{{ .component }}-config
- secretRef:
    name: {{ include "plotlens.fullname" .root }}-secrets
{{- end }}
```

**Important:** Check the current `plotlens.envFrom` definition to see exactly what it references (ConfigMap name, Secret name) and preserve the Secret reference. Only the ConfigMap name changes.

- [ ] **Step 4: Check all usages of `plotlens.envFrom` across ALL templates**

```bash
grep -rn 'plotlens.envFrom' infra/helm/plotlens/templates/
```

The new helper signature requires `(dict "root" . "component" "<name>")`. If any template (frontend, website, word-addin) uses the old single-argument form `{{ include "plotlens.envFrom" . }}`, it will break. For non-backend services that don't have their own configmap, either:
- Create a minimal configmap for them too, or
- Keep the old helper signature and add a new `plotlens.envFromComponent` helper, or
- Update those templates to not use `envFrom` (if they don't need configmap env vars)

Check the frontend, website, and word-addin deployment templates to see if they use `plotlens.envFrom`. If they do NOT use it, no changes needed. If they DO, update them accordingly.

- [ ] **Step 5: Validate template syntax**

```bash
cd infra/helm/plotlens
helm template test . --values values.yaml 2>&1 | head -20
```

Expected: may produce errors since configmap.yaml still exists and deployment templates haven't been updated yet — that's OK at this point. Just verify no syntax errors in `_helpers.tpl` itself.

- [ ] **Step 5: Commit**

```bash
git add infra/helm/plotlens/templates/_helpers.tpl
git commit -m "refactor(helm): add configmap-common helper and per-component envFrom

Preparation for splitting the shared configmap into per-component
configmaps. The common helper auto-iterates commonEnv keys so new
values are picked up without template changes."
```

### Task 4: Create per-component configmaps

**Files:**
- Create: `infra/helm/plotlens/templates/configmap-api.yaml`
- Create: `infra/helm/plotlens/templates/configmap-gateway.yaml`
- Create: `infra/helm/plotlens/templates/configmap-realtime.yaml`
- Create: `infra/helm/plotlens/templates/configmap-worker.yaml`

- [ ] **Step 1: Read the current configmap.yaml**

Read `infra/helm/plotlens/templates/configmap.yaml` to see the exact format and any keys beyond what the spec lists (e.g., `INTEGRATION_CORS_ORIGINS`). All shared keys must be in the common helper or the per-component files.

- [ ] **Step 2: Create configmap-api.yaml**

```yaml
{{- if .Values.api.enabled | default true -}}
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
{{- end }}
```

- [ ] **Step 3: Create configmap-gateway.yaml**

Same pattern, replacing `api` with `gateway`:

```yaml
{{- if .Values.gateway.enabled | default true -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "plotlens.fullname" . }}-gateway-config
  labels:
    {{- include "plotlens.labels" . | nindent 4 }}
    app.kubernetes.io/component: gateway
data:
  {{- include "plotlens.configmap-common" . | nindent 2 }}
  {{- range $key, $value := .Values.gateway.env }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
{{- end }}
```

- [ ] **Step 4: Create configmap-realtime.yaml**

Same pattern with `realtime`:

```yaml
{{- if .Values.realtime.enabled | default true -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "plotlens.fullname" . }}-realtime-config
  labels:
    {{- include "plotlens.labels" . | nindent 4 }}
    app.kubernetes.io/component: realtime
data:
  {{- include "plotlens.configmap-common" . | nindent 2 }}
  {{- range $key, $value := .Values.realtime.env }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
{{- end }}
```

- [ ] **Step 5: Create configmap-worker.yaml**

Same pattern with `worker`:

```yaml
{{- if .Values.worker.enabled | default true -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "plotlens.fullname" . }}-worker-config
  labels:
    {{- include "plotlens.labels" . | nindent 4 }}
    app.kubernetes.io/component: worker
data:
  {{- include "plotlens.configmap-common" . | nindent 2 }}
  {{- range $key, $value := .Values.worker.env }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
{{- end }}
```

- [ ] **Step 6: Commit**

```bash
git add infra/helm/plotlens/templates/configmap-api.yaml \
        infra/helm/plotlens/templates/configmap-gateway.yaml \
        infra/helm/plotlens/templates/configmap-realtime.yaml \
        infra/helm/plotlens/templates/configmap-worker.yaml
git commit -m "feat(helm): add per-component configmaps for api, gateway, realtime, worker

Each backend service gets its own configmap containing shared base
config plus component-specific env vars. This replaces the single
shared configmap so config changes only restart affected services."
```

### Task 5: Update deployment templates to use per-component configmaps

**Files:**
- Modify: `infra/helm/plotlens/templates/api-deployment.yaml`
- Modify: `infra/helm/plotlens/templates/gateway-deployment.yaml`
- Modify: `infra/helm/plotlens/templates/realtime-deployment.yaml`
- Modify: `infra/helm/plotlens/templates/worker-deployment.yaml`

- [ ] **Step 1: Update api-deployment.yaml**

Find the `checksum/config` annotation. Change:
```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```
to:
```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap-api.yaml") . | sha256sum }}
```

Find the `envFrom` block. Change the configMapRef name from the shared configmap to the component-specific one. The current `envFrom` uses the `plotlens.envFrom` helper — update the include call to pass the component:
```yaml
envFrom:
  {{- include "plotlens.envFrom" (dict "root" . "component" "api") | nindent 12 }}
```

**Important:** Read the current template first — the exact indentation and format of envFrom may vary. The key change is: the configmap reference must point to `plotlens-api-config` instead of `plotlens-config`.

- [ ] **Step 2: Update gateway-deployment.yaml**

Same changes as api, but with `gateway`:
- Checksum: reference `configmap-gateway.yaml`
- envFrom: pass `"component" "gateway"`

- [ ] **Step 3: Update realtime-deployment.yaml**

Same changes with `realtime`:
- Checksum: reference `configmap-realtime.yaml`
- envFrom: pass `"component" "realtime"`

- [ ] **Step 4: Update worker-deployment.yaml**

Same changes with `worker`:
- Checksum: reference `configmap-worker.yaml`
- envFrom: pass `"component" "worker"`

- [ ] **Step 5: Delete the old shared configmap**

```bash
git rm infra/helm/plotlens/templates/configmap.yaml
```

- [ ] **Step 6: Validate full template rendering**

```bash
cd infra/helm/plotlens
helm dependency build . 2>/dev/null
helm template test . --values values.yaml --values values-production.yaml 2>&1 | grep -A 5 'kind: ConfigMap'
```

Expected: four ConfigMaps rendered — `plotlens-api-config`, `plotlens-gateway-config`, `plotlens-realtime-config`, `plotlens-worker-config`. No `plotlens-config` (the old shared one).

- [ ] **Step 7: Verify deployment checksum annotations**

```bash
helm template test . --values values.yaml --values values-production.yaml 2>&1 | grep -B 2 'checksum/config'
```

Expected: each deployment references its own configmap file in the checksum.

- [ ] **Step 8: Verify no references to the old configmap remain**

```bash
grep -r 'plotlens.fullname.*-config"' infra/helm/plotlens/templates/ | grep -v '\-api-config\|\-gateway-config\|\-realtime-config\|\-worker-config'
```

Expected: no matches (no remaining references to the old shared `-config` name).

- [ ] **Step 9: Commit**

```bash
# Note: configmap.yaml deletion was already staged by `git rm` in Step 5
git add infra/helm/plotlens/templates/api-deployment.yaml \
        infra/helm/plotlens/templates/gateway-deployment.yaml \
        infra/helm/plotlens/templates/realtime-deployment.yaml \
        infra/helm/plotlens/templates/worker-deployment.yaml
git status  # verify configmap.yaml deletion + 4 modified deployments are staged
git commit -m "refactor(helm): switch deployments to per-component configmaps

Each deployment now references its own configmap for both the
checksum annotation and envFrom. Config changes to one service
no longer trigger rolling restarts of unrelated services.

Removes the old shared configmap.yaml template."
```

### Task 6: Phase 1 validation

- [ ] **Step 1: Full helm template dry run**

```bash
cd infra/helm/plotlens
helm dependency build . 2>/dev/null
helm template test . --values values.yaml --values values-production.yaml > /tmp/phase1-rendered.yaml 2>&1
echo "Exit code: $?"
```

Expected: exit code 0, no errors.

- [ ] **Step 2: Verify all services render correctly**

```bash
grep 'kind: Deployment' /tmp/phase1-rendered.yaml | wc -l
grep 'kind: ConfigMap' /tmp/phase1-rendered.yaml | wc -l
grep 'kind: Service' /tmp/phase1-rendered.yaml | wc -l
```

Expected: 8 Deployments (api, frontend, gateway, qdrant, realtime, website, word-addin, worker), 4 ConfigMaps (api, gateway, realtime, worker), 7 Services.

- [ ] **Step 3: Verify timeout change**

```bash
grep 'timeout' .github/workflows/build-push.yaml
```

Expected: `25m` everywhere.

---

## Phase 2: Pin Image Tags

### Task 7: Add `built-services` output to the build job

**Files:**
- Modify: `.github/workflows/build-push.yaml`

- [ ] **Step 1: Read the build job structure and understand the service detection mechanism**

```bash
grep -n 'changes\|matrix\|MATRIX\|built\|service' .github/workflows/build-push.yaml | head -40
```

Read `.github/workflows/build-push.yaml` in full. Identify:
- The `changes` (or `Detect Changes`) job — look for `paths-filter` or conditional outputs per service
- How the deploy job currently gets the list of changed services — look for the `MATRIX` variable in the deploy step (it contains `{"service":["word-addin"]}` or similar)
- Whether builds use a matrix strategy or individual conditional jobs

**The workflow likely follows one of two patterns:**

**Pattern A — Matrix build with changes job outputs:**
The `changes` job outputs booleans like `gateway: true`, `api: false`, etc. A later job builds the MATRIX from these.
→ Add a step to the `changes` job (or the job that constructs MATRIX) that collects service names into a `built-services` output.

**Pattern B — Individual conditional build jobs:**
Each service has its own build job (e.g., `build-api`, `build-gateway`) with an `if:` condition.
→ Add an aggregation step after all build jobs that collects which ones ran.

- [ ] **Step 2: Add a `built-services` output**

Based on what you found in Step 1, add the output. The most likely implementation:

Find the job/step that constructs the `MATRIX` JSON (search for `MATRIX=` or `matrix=`). In the same step, add:

```bash
# Collect built services as comma-separated list for resolve-tags job
BUILT_LIST=$(echo "$MATRIX" | jq -r '.service[]?' | tr '\n' ',' | sed 's/,$//')
echo "built-services=${BUILT_LIST}" >> "$GITHUB_OUTPUT"
```

Then add to that job's `outputs:` block:
```yaml
outputs:
  # ... existing outputs ...
  built-services: ${{ steps.<step-id>.outputs.built-services }}
```

Replace `<step-id>` with the actual step ID where you added the output.

**Verify:** `built-services` should produce values like `word-addin` or `api,worker,frontend`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-push.yaml
git commit -m "feat(ci): add built-services output to build pipeline

The deploy job needs to know which services were built in this run
so it can resolve image tags for unchanged services via crane."
```

### Task 8: Add `resolve-tags` job

**Files:**
- Modify: `.github/workflows/build-push.yaml`

- [ ] **Step 1: Add crane installation step**

Add a step to install `crane` in the `resolve-tags` job. The self-hosted runner may not have it:

```yaml
- name: Install crane
  run: |
    VERSION=v0.20.3
    curl -sL "https://github.com/google/go-containerregistry/releases/download/${VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xzf - -C /usr/local/bin crane
    crane version
```

- [ ] **Step 2: Add the `resolve-tags` job**

Insert this job between `build`/`scan` and `deploy`. It needs:
- `needs: [build, scan]` (or whatever the build/scan jobs are named — check the actual workflow)
- Runs on the self-hosted runner (needs Harbor network access)
- Harbor login for crane authentication
- The tag resolution loop from the spec

```yaml
resolve-tags:
  name: Resolve Image Tags
  needs: [build, scan]
  if: # Copy the exact `if:` condition from the existing deploy job in the workflow.
      # Find it with: grep -A 2 'Deploy (homelab)' .github/workflows/build-push.yaml | grep 'if:'
      # It likely checks environment == 'homelab' and deploy is enabled.
  runs-on: [self-hosted, plotlens]
  outputs:
    api-tag: ${{ steps.tags.outputs.api }}
    gateway-tag: ${{ steps.tags.outputs.gateway }}
    worker-tag: ${{ steps.tags.outputs.worker }}
    realtime-tag: ${{ steps.tags.outputs.realtime }}
    frontend-tag: ${{ steps.tags.outputs.frontend }}
    website-tag: ${{ steps.tags.outputs.website }}
    word-addin-tag: ${{ steps.tags.outputs['word-addin'] }}
  steps:
    - name: Install crane
      run: |
        if ! command -v crane &>/dev/null; then
          VERSION=v0.20.3
          curl -sL "https://github.com/google/go-containerregistry/releases/download/${VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xzf - -C /usr/local/bin crane
        fi
        crane version

    - name: Login to Harbor
      run: |
        crane auth login harbor.corbello.io \
          -u "${{ secrets.HARBOR_USERNAME }}" \
          -p "${{ secrets.HARBOR_PASSWORD }}"

    - name: Resolve image tags
      id: tags
      run: |
        set -euo pipefail
        COMMIT_SHA="${{ github.sha }}"
        SERVICES="api gateway worker realtime frontend website word-addin"
        BUILT='${{ needs.build.outputs.built-services }}'

        for SVC in $SERVICES; do
          REPO="plotlens/plotlens-${SVC}"
          if echo "$BUILT" | grep -qw "$SVC"; then
            echo "::notice::${SVC}: built this run, using SHA tag ${COMMIT_SHA}"
            echo "${SVC}=${COMMIT_SHA}" >> "$GITHUB_OUTPUT"
          else
            DIGEST=$(crane digest "harbor.corbello.io/${REPO}:latest" 2>/dev/null || true)
            if [[ -n "$DIGEST" ]]; then
              crane cp "harbor.corbello.io/${REPO}@${DIGEST}" "harbor.corbello.io/${REPO}:${COMMIT_SHA}"
              echo "::notice::${SVC}: retagged ${DIGEST} as ${COMMIT_SHA}"
              echo "${SVC}=${COMMIT_SHA}" >> "$GITHUB_OUTPUT"
            else
              echo "::error::No image found for harbor.corbello.io/${REPO}:latest"
              exit 1
            fi
          fi
        done
```

- [ ] **Step 3: Update the deploy job to depend on `resolve-tags`**

Change the deploy job's `needs` to include `resolve-tags`:
```yaml
needs: [resolve-tags, ...]
```

- [ ] **Step 4: Update the Helm upgrade command in the deploy step**

Replace the current `SET_FLAGS` loop and `MATRIX`-based tag logic with explicit `--set` flags for all services:

```yaml
helm upgrade plotlens infra/helm/plotlens/ \
  --namespace plotlens \
  --values infra/helm/plotlens/values-production.yaml \
  --install --atomic --cleanup-on-fail \
  --history-max 5 --timeout 25m \
  "${FORCE_FLAGS[@]}" \
  --set api.image.tag=${{ needs['resolve-tags'].outputs['api-tag'] }} \
  --set gateway.image.tag=${{ needs['resolve-tags'].outputs['gateway-tag'] }} \
  --set worker.image.tag=${{ needs['resolve-tags'].outputs['worker-tag'] }} \
  --set realtime.image.tag=${{ needs['resolve-tags'].outputs['realtime-tag'] }} \
  --set frontend.image.tag=${{ needs['resolve-tags'].outputs['frontend-tag'] }} \
  --set website.image.tag=${{ needs['resolve-tags'].outputs['website-tag'] }} \
  --set wordAddin.image.tag=${{ needs['resolve-tags'].outputs['word-addin-tag'] }}
```

**Important:** Keep the existing `FORCE_FLAGS` logic. Find and remove the `SET_FLAGS` loop and `HELM_KEY` map:

```bash
# Find the code blocks to remove:
grep -n 'SET_FLAGS\|HELM_KEY\|declare -A' .github/workflows/build-push.yaml
```

You should find:
- A `declare -A HELM_KEY=( ... )` block mapping service names to Helm values keys
- A `for SERVICE in $SERVICES; do ... SET_FLAGS+=(...) ... done` loop
- A `"${SET_FLAGS[@]}"` reference in the helm upgrade command

Remove all three. The explicit `--set` flags above replace this entire mechanism.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-push.yaml
git commit -m "feat(ci): add resolve-tags job for deterministic image pinning

Every deploy now resolves a commit-SHA tag for ALL services, not just
the ones that changed. Unchanged services get their :latest digest
retagged via crane cp (no layer re-push). This ensures only services
with actual image changes get new pods during Helm upgrade."
```

### Task 9: Update Helm values to remove `:latest` defaults

**Files:**
- Modify: `infra/helm/plotlens/values.yaml`
- Modify: `infra/helm/plotlens/values-production.yaml`

- [ ] **Step 1: Read values.yaml image blocks**

Read `infra/helm/plotlens/values.yaml` and find every `image:` block. They look like:
```yaml
image:
  repository: plotlens-api
  tag: latest
  pullPolicy: Always
```

- [ ] **Step 2: Update values.yaml — change all image tags and pullPolicy**

For each service (gateway, api, worker, realtime, frontend, website, wordAddin), change:
```yaml
tag: latest    →  tag: ""
pullPolicy: Always  →  pullPolicy: IfNotPresent
```

If a service doesn't explicitly set `pullPolicy`, add `pullPolicy: IfNotPresent`.

- [ ] **Step 3: Update values-production.yaml**

Read `infra/helm/plotlens/values-production.yaml`. If any service overrides `image.tag` or `image.pullPolicy`, update them the same way. If production values don't override image blocks, no changes needed here (they'll inherit from values.yaml).

- [ ] **Step 4: Verify template still renders**

```bash
cd infra/helm/plotlens
helm template test . --values values.yaml --values values-production.yaml \
  --set api.image.tag=abc123 \
  --set gateway.image.tag=abc123 \
  --set worker.image.tag=abc123 \
  --set realtime.image.tag=abc123 \
  --set frontend.image.tag=abc123 \
  --set website.image.tag=abc123 \
  --set wordAddin.image.tag=abc123 \
  2>&1 | grep 'image:' | head -10
```

Expected: all images show `harbor.corbello.io/plotlens/plotlens-<service>:abc123`.

- [ ] **Step 5: Verify empty tag fails gracefully**

```bash
helm template test . --values values.yaml --values values-production.yaml 2>&1 | grep 'image:' | head -5
```

Expected: images show `harbor.corbello.io/plotlens/plotlens-<service>:` (empty tag). This is expected — CI always provides tags. Local dev would need to pass `--set` flags.

- [ ] **Step 6: Commit**

```bash
git add infra/helm/plotlens/values.yaml infra/helm/plotlens/values-production.yaml
git commit -m "feat(helm): remove :latest defaults, switch to IfNotPresent pull policy

CI now provides explicit SHA tags for every service via the
resolve-tags job. IfNotPresent prevents unnecessary re-pulls
since SHA-tagged images are immutable."
```

### Task 10: Phase 2 validation

- [ ] **Step 1: Full workflow YAML syntax check**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-push.yaml'))" && echo "YAML valid" || echo "YAML INVALID"
```

- [ ] **Step 2: Verify resolve-tags job outputs all 7 services**

```bash
grep -A 20 'resolve-tags:' .github/workflows/build-push.yaml | grep 'outputs:' -A 10
```

Expected: 7 output keys (api-tag through word-addin-tag).

- [ ] **Step 3: Verify deploy step references all 7 tags**

```bash
grep 'needs.resolve-tags.outputs' .github/workflows/build-push.yaml
```

Expected: 7 `--set` lines.

---

## Phase 3: Model Extraction + Image Optimization

### Task 11: Add worker models config to values.yaml

**Files:**
- Modify: `infra/helm/plotlens/values.yaml`
- Modify: `infra/helm/plotlens/values-production.yaml`

- [ ] **Step 1: Add models config block to worker in values.yaml**

Add under the `worker:` section:

```yaml
worker:
  # ... existing config ...
  models:
    enabled: true
    storageClassName: nfs-csi
    storageSize: 2Gi
    seedJob:
      enabled: false  # disabled by default, enable in production values
      spacyVersion: "3.8.11"
      models:
        - name: en_core_web_trf
          version: "3.8.0"
        - name: en_core_web_lg
          version: "3.8.0"
  ephemeralStorage:
    requests: 2Gi
    limits: 4Gi
```

- [ ] **Step 2: Enable seed job in values-production.yaml**

Add under the `worker:` section in production values:

```yaml
worker:
  # ... existing config ...
  models:
    seedJob:
      enabled: true
```

- [ ] **Step 3: Commit**

```bash
git add infra/helm/plotlens/values.yaml infra/helm/plotlens/values-production.yaml
git commit -m "feat(helm): add worker models config for PVC-based spaCy model loading

Configures NFS PVC for spaCy models and seed job settings.
Seed job disabled by default, enabled in production values."
```

### Task 12: Create models PVC template

**Files:**
- Create: `infra/helm/plotlens/templates/models-pvc.yaml`

- [ ] **Step 1: Create the PVC template**

```yaml
{{- if .Values.worker.models.enabled -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "plotlens.fullname" . }}-models
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "plotlens.labels" . | nindent 4 }}
    app.kubernetes.io/component: worker
spec:
  accessModes: [ReadWriteMany]
  storageClassName: {{ .Values.worker.models.storageClassName }}
  resources:
    requests:
      storage: {{ .Values.worker.models.storageSize }}
{{- end }}
```

- [ ] **Step 2: Verify it renders**

```bash
cd infra/helm/plotlens
helm template test . --values values.yaml --values values-production.yaml \
  --set api.image.tag=x --set gateway.image.tag=x --set worker.image.tag=x \
  --set realtime.image.tag=x --set frontend.image.tag=x --set website.image.tag=x \
  --set wordAddin.image.tag=x \
  2>&1 | grep -A 10 'kind: PersistentVolumeClaim'
```

Expected: PVC named `plotlens-models` with `ReadWriteMany`, `nfs-csi`, `2Gi`.

- [ ] **Step 3: Commit**

```bash
git add infra/helm/plotlens/templates/models-pvc.yaml
git commit -m "feat(helm): add NFS PVC for spaCy models

ReadWriteMany PVC allows the seed Job to write and all worker
replicas to mount simultaneously. Workers mount read-only."
```

### Task 13: Create model seed Job template

**Files:**
- Create: `infra/helm/plotlens/templates/model-seed-job.yaml`

- [ ] **Step 1: Create the seed Job template**

```yaml
{{- if and .Values.worker.models.enabled .Values.worker.models.seedJob.enabled -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "plotlens.fullname" . }}-model-seed
  labels:
    {{- include "plotlens.labels" . | nindent 4 }}
    app.kubernetes.io/component: worker
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: hook-succeeded,before-hook-creation
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        {{- include "plotlens.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: model-seed
    spec:
      restartPolicy: OnFailure
      securityContext:
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
      containers:
        - name: seed
          image: harbor.corbello.io/dockerhub-cache/library/python:3.11-slim
          command:
            - sh
            - -c
            - |
              set -eu
              echo "Installing spaCy {{ .Values.worker.models.seedJob.spacyVersion }}..."
              pip install --no-cache-dir spacy=={{ .Values.worker.models.seedJob.spacyVersion }}

              {{- range .Values.worker.models.seedJob.models }}
              echo "Installing model {{ .name }}-{{ .version }}..."
              pip install --no-cache-dir --target=/models \
                "https://github.com/explosion/spacy-models/releases/download/{{ .name }}-{{ .version }}/{{ .name }}-{{ .version }}.tar.gz"
              {{- end }}

              echo "Models installed:"
              ls -la /models/
              echo "Done."
          volumeMounts:
            - name: models
              mountPath: /models
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: {{ include "plotlens.fullname" . }}-models
{{- end }}
```

- [ ] **Step 2: Verify it renders**

```bash
cd infra/helm/plotlens
helm template test . --values values.yaml --values values-production.yaml \
  --set api.image.tag=x --set gateway.image.tag=x --set worker.image.tag=x \
  --set realtime.image.tag=x --set frontend.image.tag=x --set website.image.tag=x \
  --set wordAddin.image.tag=x \
  2>&1 | grep -A 30 'kind: Job'
```

Expected: Job with `post-install,post-upgrade` hook, pip install commands for both models.

- [ ] **Step 3: Commit**

```bash
git add infra/helm/plotlens/templates/model-seed-job.yaml
git commit -m "feat(helm): add model seed Job as Helm post-install/post-upgrade hook

Downloads spaCy models to the NFS PVC via pip --target=/models.
Runs after each install/upgrade. before-hook-creation policy ensures
stale jobs are cleaned up before a new one runs."
```

### Task 14: Update worker deployment for PVC mount + ephemeral-storage

**Files:**
- Modify: `infra/helm/plotlens/templates/worker-deployment.yaml`

- [ ] **Step 1: Read the current worker-deployment.yaml**

Read the full file to identify exact insertion points for:
- The `PYTHONPATH` env var
- The models volume mount
- The models volume definition
- The ephemeral-storage resource limits

- [ ] **Step 2: Add PYTHONPATH env var**

In the `env:` section (or create one if it only uses `envFrom`), add:

```yaml
{{- if .Values.worker.models.enabled }}
- name: PYTHONPATH
  value: "/models:$(PYTHONPATH)"
{{- end }}
```

**Note:** The `$(PYTHONPATH)` uses Kubernetes variable substitution to preserve any existing PYTHONPATH from the container image. If no prior PYTHONPATH env var is defined in this block, it resolves to empty string (yielding `/models:` — the trailing colon is harmless in Python path resolution). Place this before the `envFrom` block or in the existing `env` block.

- [ ] **Step 3: Add models volume mount**

In the container's `volumeMounts:` section, add:

```yaml
{{- if .Values.worker.models.enabled }}
- name: models
  mountPath: /models
  readOnly: true
{{- end }}
```

- [ ] **Step 4: Add models volume**

In the pod's `volumes:` section, add:

```yaml
{{- if .Values.worker.models.enabled }}
- name: models
  persistentVolumeClaim:
    claimName: {{ include "plotlens.fullname" . }}-models
{{- end }}
```

- [ ] **Step 5: Add ephemeral-storage to resources**

In the `resources:` block, add ephemeral-storage. The current resources come from `{{ toYaml .Values.worker.resources | nindent 12 }}`. Add ephemeral-storage to the values rather than the template — this was already done in Task 11. Verify the production values include it:

```yaml
# In values-production.yaml under worker:
resources:
  requests:
    cpu: 500m
    memory: 512Mi
    ephemeral-storage: 2Gi
  limits:
    cpu: "2"
    memory: 2Gi
    ephemeral-storage: 4Gi
```

If the existing production values already define `worker.resources`, add the `ephemeral-storage` keys to the existing block rather than replacing it.

- [ ] **Step 6: Verify template renders**

```bash
cd infra/helm/plotlens
helm template test . --values values.yaml --values values-production.yaml \
  --set api.image.tag=x --set gateway.image.tag=x --set worker.image.tag=x \
  --set realtime.image.tag=x --set frontend.image.tag=x --set website.image.tag=x \
  --set wordAddin.image.tag=x \
  2>&1 | grep -A 50 'component: worker' | head -60
```

Expected: worker deployment shows `PYTHONPATH: /models`, models volumeMount, models volume with PVC.

- [ ] **Step 7: Commit**

```bash
git add infra/helm/plotlens/templates/worker-deployment.yaml \
        infra/helm/plotlens/values-production.yaml
git commit -m "feat(helm): mount models PVC in worker, add ephemeral-storage limits

Worker mounts NFS PVC at /models (read-only) with PYTHONPATH set so
spaCy discovers models as installed Python packages. Ephemeral-storage
limits prevent eviction from image layer unpacking."
```

### Task 15: Remove model downloads from base image Dockerfile

**Files:**
- Modify: `docker/python-base-spacy/Dockerfile`

- [ ] **Step 1: Read the current Dockerfile**

Read `docker/python-base-spacy/Dockerfile` in full.

- [ ] **Step 2: Remove model download lines**

The Dockerfile has lines like:
```dockerfile
RUN pip install --no-cache-dir \
    "https://github.com/explosion/spacy-models/releases/download/${MODEL_NAME}-${MODEL_VERSION}/${MODEL_NAME}-${MODEL_VERSION}-py3-none-any.whl"
```

And a verification step:
```dockerfile
RUN python -c "import spacy; nlp = spacy.load('${MODEL_NAME}'); print(...)"
```

Remove the model download `RUN` line and the model verification `RUN` line. Keep the spaCy package install itself — we still need the spaCy library, just not the models.

Add a comment explaining why:
```dockerfile
# spaCy models are loaded from NFS PVC at runtime via PYTHONPATH=/models
# See: infra/helm/plotlens/templates/model-seed-job.yaml
```

- [ ] **Step 3: Also remove the MODEL_NAME and MODEL_VERSION ARGs if they're no longer used**

If `MODEL_NAME` and `MODEL_VERSION` are only used for the model download, remove the `ARG` lines too. If they're referenced elsewhere (e.g., image tag), keep them.

- [ ] **Step 4: Commit**

```bash
git add docker/python-base-spacy/Dockerfile
git commit -m "feat(docker): remove baked-in spaCy models from base image

Models are now loaded from NFS PVC at runtime via PYTHONPATH.
This reduces the base image by ~500MB. The seed Job
(model-seed-job.yaml) handles model installation."
```

### Task 16: Optimize worker Dockerfile

**Files:**
- Modify: `py/apps/worker/Dockerfile`

- [ ] **Step 1: Read the current worker Dockerfile**

Read `py/apps/worker/Dockerfile` in full.

- [ ] **Step 2: Add `--no-cache-dir` to all pip install commands**

Find every `pip install` line. If any are missing `--no-cache-dir`, add it:
```dockerfile
RUN pip install --no-cache-dir ...
```

- [ ] **Step 3: Add bytecode stripping in the final stage**

After the last `COPY` in the runtime stage, before the `USER` directive, add:

```dockerfile
# Strip bytecode and pip cache to reduce image size
RUN find /usr/local/lib/python3.11 -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
    find /usr/local/lib/python3.11 -name '*.pyc' -delete 2>/dev/null; \
    rm -rf /root/.cache/pip 2>/dev/null; \
    true
```

- [ ] **Step 4: Audit for unnecessary build artifacts**

Check if the builder stage leaves any dev packages, compilers, or header files that leak into the runtime. The runtime stage should `COPY --from=builder` only the necessary paths. Verify this is already the case.

- [ ] **Step 5: Commit**

```bash
git add py/apps/worker/Dockerfile
git commit -m "fix(docker): optimize worker image — no-cache-dir, strip bytecode

Adds --no-cache-dir to all pip installs and strips __pycache__
in the final stage. Combined with model extraction, reduces the
worker image from ~5GB to ~1-1.5GB."
```

### Task 17: Phase 3 validation

- [ ] **Step 1: Full helm template dry run with all phases applied**

```bash
cd infra/helm/plotlens
helm template test . --values values.yaml --values values-production.yaml \
  --set api.image.tag=abc123 \
  --set gateway.image.tag=abc123 \
  --set worker.image.tag=abc123 \
  --set realtime.image.tag=abc123 \
  --set frontend.image.tag=abc123 \
  --set website.image.tag=abc123 \
  --set wordAddin.image.tag=abc123 \
  > /tmp/full-rendered.yaml 2>&1
echo "Exit code: $?"
```

Expected: exit code 0.

- [ ] **Step 2: Verify PVC and Job rendered**

```bash
grep 'kind: PersistentVolumeClaim' /tmp/full-rendered.yaml
grep 'kind: Job' /tmp/full-rendered.yaml
```

Expected: 1 PVC, 1 Job.

- [ ] **Step 3: Verify worker has PYTHONPATH and models mount**

```bash
grep -A 3 'PYTHONPATH' /tmp/full-rendered.yaml
grep -A 3 'name: models' /tmp/full-rendered.yaml
```

Expected: `PYTHONPATH: /models`, volume mount at `/models` with `readOnly: true`.

- [ ] **Step 4: Verify worker has ephemeral-storage**

```bash
grep 'ephemeral-storage' /tmp/full-rendered.yaml
```

Expected: `2Gi` request, `4Gi` limit.

- [ ] **Step 5: Verify all images use IfNotPresent**

```bash
grep 'imagePullPolicy' /tmp/full-rendered.yaml | sort | uniq -c
```

Expected: all show `IfNotPresent`.

- [ ] **Step 6: Run helm lint**

```bash
cd infra/helm/plotlens
helm lint . --values values.yaml --values values-production.yaml \
  --set api.image.tag=abc123 --set gateway.image.tag=abc123 \
  --set worker.image.tag=abc123 --set realtime.image.tag=abc123 \
  --set frontend.image.tag=abc123 --set website.image.tag=abc123 \
  --set wordAddin.image.tag=abc123
```

Expected: `0 chart(s) failed`. Warnings are OK (info-level), errors are not.

---

## Final: Create PR

### Task 18: Push and create PR

- [ ] **Step 1: Review all commits**

```bash
git log --oneline main..HEAD
```

Expected: ~10 commits covering all three phases.

- [ ] **Step 2: Push branch**

```bash
git push -u origin fix/deploy-reliability
```

- [ ] **Step 3: Create PR**

```bash
gh pr create --title "fix: deploy reliability — pinned tags, split configmaps, model extraction" --body "$(cat <<'PREOF'
## Summary

Fixes unreliable PlotLens deploys to the homelab K3s cluster. A deploy that only changed `word-addin` caused ALL pods to restart, triggering a 16m+ pull of the 5GB worker image, ephemeral-storage eviction, and a Helm timeout.

### Changes

**Phase 1 — Immediate relief:**
- Increase Helm timeout from 15m to 25m
- Split shared configmap into per-component configmaps (api, gateway, realtime, worker) so config changes only restart affected services

**Phase 2 — Deterministic deploys:**
- Add `resolve-tags` CI job that pins ALL service images to commit SHA tags using `crane cp`
- Change default `imagePullPolicy` to `IfNotPresent` (SHA tags are immutable)
- Remove `:latest` as default tag — CI must provide tags

**Phase 3 — Image size reduction:**
- Extract spaCy NLP models (~500MB) from worker image to NFS PVC
- Helm hook Job seeds models to PVC on install/upgrade
- Worker mounts PVC read-only at `/models` via `PYTHONPATH`
- Add `--no-cache-dir` and bytecode stripping to Dockerfiles
- Add `ephemeral-storage` resource limits to prevent eviction

### Expected impact
- Worker image: ~5GB → ~1-1.5GB
- Deploy time for unchanged services: ~0s (no restart)
- Deploy time for changed services: 1-2 min (vs 16+ min)
- No more spurious timeouts or ephemeral-storage evictions

### Risk/Rollback
- Phase 1-2: `helm rollback` restores previous state
- Phase 3: If PVC mount fails, Celery probe catches it. Rollback: revert Dockerfile to bake models back in

### Testing
- `helm template` dry-run validates all template changes
- First deploy should be monitored — watch for configmap reference errors or missing env vars

Spec: cortech-infra `docs/superpowers/specs/2026-03-23-plotlens-deploy-reliability-design.md`
PREOF
)"
```

- [ ] **Step 4: Return the PR URL**
