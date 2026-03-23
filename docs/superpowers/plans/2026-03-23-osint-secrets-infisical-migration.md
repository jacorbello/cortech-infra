# osint-secrets Infisical Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace plaintext `osint-secrets` K8s Secret with an operator-managed secret synced from Infisical.

**Architecture:** Install the Infisical Secrets Operator via ArgoCD Helm application. Create a dedicated `/osint` folder in Infisical with the 6 required secrets. Deploy an `InfisicalSecret` CR that syncs those secrets into a managed K8s Secret, then update all deployment `secretKeyRef` keys to match Infisical naming.

**Tech Stack:** Kubernetes, Infisical Secrets Operator (Helm), ArgoCD, Kustomize, Infisical CLI

**Spec:** `docs/superpowers/specs/2026-03-23-osint-secrets-infisical-design.md`

---

### Task 1: Create `/osint` folder in Infisical and copy secrets

**Files:** None (Infisical CLI operations)

This is a manual/CLI task — create the folder and copy the 6 secrets that osint needs.

- [ ] **Step 1: Create the `/osint` folder in Infisical prod**

```bash
infisical secrets folders create --env prod --path / --name osint
```

- [ ] **Step 2: Copy secrets to `/osint` folder**

```bash
for key in REDIS_PASSWORD REDIS_URL CELERY_BROKER_URL CELERY_RESULT_BACKEND ACLED_EMAIL ACLED_PASSWORD; do
  value=$(infisical secrets get "$key" --env prod --path / -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['secretValue'])")
  infisical secrets set "${key}=${value}" --env prod --path /osint
done
```

- [ ] **Step 3: Verify all 6 secrets exist in `/osint`**

```bash
infisical secrets --env prod --path /osint
```

Expected: Table showing `REDIS_PASSWORD`, `REDIS_URL`, `CELERY_BROKER_URL`, `CELERY_RESULT_BACKEND`, `ACLED_EMAIL`, `ACLED_PASSWORD`.

---

### Task 2: Create ArgoCD application for Infisical Secrets Operator

**Files:**
- Create: `apps/infisical-operator/argocd-application.yaml`

- [ ] **Step 1: Create the ArgoCD application manifest**

Create `apps/infisical-operator/argocd-application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infisical-operator
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
    chart: secrets-operator
    targetRevision: "0.*"
    helm:
      releaseName: infisical-operator
  destination:
    server: https://kubernetes.default.svc
    namespace: infisical-operator
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Note: `targetRevision: "0.*"` pins to 0.x to avoid surprise major version bumps.

- [ ] **Step 2: Commit**

```bash
git add apps/infisical-operator/argocd-application.yaml
git commit -m "feat(infisical): add ArgoCD application for secrets operator"
```

---

### Task 3: Deploy operator and create bootstrap secret

**Files:** None (kubectl operations, not committed to git)

The operator must be running before the `InfisicalSecret` CR can be applied. This task deploys the ArgoCD app and creates the bootstrap secret.

- [ ] **Step 1: Push the branch and apply the ArgoCD application**

```bash
git push
ssh root@192.168.1.52 "kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infisical-operator
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
    chart: secrets-operator
    targetRevision: \"0.*\"
    helm:
      releaseName: infisical-operator
  destination:
    server: https://kubernetes.default.svc
    namespace: infisical-operator
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF"
```

- [ ] **Step 2: Wait for operator pod to be running**

```bash
ssh root@192.168.1.52 "kubectl get pods -n infisical-operator -w"
```

Expected: One or more pods in `Running` state.

- [ ] **Step 3: Verify CRDs are installed**

```bash
ssh root@192.168.1.52 "kubectl get crd | grep infisical"
```

Expected: `infisicalsecrets.secrets.infisical.com` CRD present.

- [ ] **Step 4: Create the bootstrap machine identity secret**

```bash
ssh root@192.168.1.52 "kubectl -n infisical-operator create secret generic infisical-machine-identity \
  --from-literal=clientId='d091297e-9918-480a-812f-1eef7ef96cab' \
  --from-literal=clientSecret='<retrieve from Infisical UI or password manager>'"
```

- [ ] **Step 5: Verify bootstrap secret exists**

```bash
ssh root@192.168.1.52 "kubectl get secret -n infisical-operator infisical-machine-identity"
```

Expected: Secret listed with `Opaque` type, 2 data items.

---

### Task 4: Replace plaintext secrets.yaml with InfisicalSecret CR

**Files:**
- Delete: `apps/osint/base/secrets.yaml` (old plaintext Secret)
- Create: `apps/osint/base/infisical-secret.yaml` (new InfisicalSecret CR)
- Modify: `apps/osint/base/kustomization.yaml:6` (update resource reference)

- [ ] **Step 1: Create the InfisicalSecret CR file**

Create `apps/osint/base/infisical-secret.yaml`:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: osint-secrets
  namespace: osint
spec:
  hostAPI: http://infisical.infisical.svc.cluster.local
  resyncInterval: 60
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: homelab
        envSlug: prod
        secretsPath: /osint
      credentialsRef:
        secretName: infisical-machine-identity
        secretNamespace: infisical-operator
  managedSecretReference:
    secretName: osint-secrets
    secretNamespace: osint
    secretType: Opaque
    creationPolicy: Orphan
  autoReload:
    deployments:
      - name: osint-worker
      - name: osint-beat
      - name: osint-core
```

- [ ] **Step 2: Update kustomization.yaml to reference the new file**

In `apps/osint/base/kustomization.yaml`, change line 6:

```yaml
# Old:
  - secrets.yaml
# New:
  - infisical-secret.yaml
```

- [ ] **Step 3: Delete the old plaintext secrets.yaml**

```bash
rm apps/osint/base/secrets.yaml
```

- [ ] **Step 4: Commit**

```bash
git add apps/osint/base/infisical-secret.yaml apps/osint/base/kustomization.yaml
git rm apps/osint/base/secrets.yaml
git commit -m "feat(osint): replace plaintext secrets with InfisicalSecret CR

Removes plaintext osint-secrets and replaces with InfisicalSecret CR
that syncs from Infisical prod /osint folder via the secrets operator."
```

---

### Task 5: Update deployment secretKeyRef keys to match Infisical naming

**Files:**
- Modify: `apps/osint/base/osint-worker/deployment.yaml` (lines 47-60, 75-82)
- Modify: `apps/osint/base/osint-beat/deployment.yaml` (lines 47-60, 75-82)
- Modify: `apps/osint/base/osint-core/deployment.yaml` (lines 44-56)

All three deployments reference `osint-secrets` keys using lowercase-hyphenated names. These must be updated to match the uppercase Infisical key names.

- [ ] **Step 1: Update osint-core deployment**

In `apps/osint/base/osint-core/deployment.yaml`, change these `secretKeyRef.key` values:

```yaml
# redis-url -> REDIS_URL (line 46)
                  key: REDIS_URL
# celery-broker-url -> CELERY_BROKER_URL (line 51)
                  key: CELERY_BROKER_URL
# celery-result-backend -> CELERY_RESULT_BACKEND (line 56)
                  key: CELERY_RESULT_BACKEND
```

- [ ] **Step 2: Update osint-worker deployment**

In `apps/osint/base/osint-worker/deployment.yaml`, change these `secretKeyRef.key` values:

```yaml
# redis-url -> REDIS_URL
                  key: REDIS_URL
# celery-broker-url -> CELERY_BROKER_URL
                  key: CELERY_BROKER_URL
# celery-result-backend -> CELERY_RESULT_BACKEND
                  key: CELERY_RESULT_BACKEND
# acled-email -> ACLED_EMAIL
                  key: ACLED_EMAIL
# acled-password -> ACLED_PASSWORD
                  key: ACLED_PASSWORD
```

- [ ] **Step 3: Update osint-beat deployment**

In `apps/osint/base/osint-beat/deployment.yaml`, change the same keys as the worker:

```yaml
# redis-url -> REDIS_URL
                  key: REDIS_URL
# celery-broker-url -> CELERY_BROKER_URL
                  key: CELERY_BROKER_URL
# celery-result-backend -> CELERY_RESULT_BACKEND
                  key: CELERY_RESULT_BACKEND
# acled-email -> ACLED_EMAIL
                  key: ACLED_EMAIL
# acled-password -> ACLED_PASSWORD
                  key: ACLED_PASSWORD
```

- [ ] **Step 4: Commit**

```bash
git add apps/osint/base/osint-core/deployment.yaml \
        apps/osint/base/osint-worker/deployment.yaml \
        apps/osint/base/osint-beat/deployment.yaml
git commit -m "fix(osint): update secretKeyRef keys to match Infisical naming

Uppercase key names (REDIS_URL, CELERY_BROKER_URL, etc.) match
the keys synced from Infisical by the secrets operator."
```

---

### Task 6: Add .infisical.json to .gitignore and cleanup

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add `.infisical.json` to `.gitignore`**

Append to the "Environment files" section in `.gitignore`:

```
.infisical.json
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: add .infisical.json to gitignore"
```

---

### Task 7: Verify end-to-end on cluster

**Files:** None (verification only)

- [ ] **Step 1: Push all changes**

```bash
git push
```

- [ ] **Step 2: Verify the InfisicalSecret CR is syncing**

```bash
ssh root@192.168.1.52 "kubectl get infisicalsecret -n osint"
```

Expected: `osint-secrets` listed with a healthy status.

- [ ] **Step 3: Verify the managed K8s Secret was created with correct keys**

```bash
ssh root@192.168.1.52 "kubectl get secret osint-secrets -n osint -o jsonpath='{.data}' | python3 -c \"import sys,json; print('\n'.join(json.loads(sys.stdin.read()).keys()))\""
```

Expected: `REDIS_PASSWORD`, `REDIS_URL`, `CELERY_BROKER_URL`, `CELERY_RESULT_BACKEND`, `ACLED_EMAIL`, `ACLED_PASSWORD`

- [ ] **Step 4: Verify deployments are running with new secret keys**

```bash
ssh root@192.168.1.52 "kubectl get pods -n osint"
```

Expected: All `osint-worker`, `osint-beat`, `osint-core` pods in `Running` state (may have recently restarted due to `autoReload`).

- [ ] **Step 5: Smoke test the API**

```bash
ssh root@192.168.1.52 "kubectl exec -n osint deploy/osint-core -- env | grep OSINT_REDIS_URL"
```

Expected: `OSINT_REDIS_URL` is set to the Redis connection string from Infisical.

---

## Ordering Notes

- **Tasks 1-3 must be sequential** — Infisical folder must exist before operator syncs, operator must be running before InfisicalSecret CR is applied.
- **Tasks 4-6 can be done in parallel** (all are git changes), but must be pushed after Task 3 is complete.
- **Task 7** is the final verification gate.

## Rollback

If anything goes wrong after deployment:

1. `creationPolicy: Orphan` means the managed K8s Secret survives CR deletion
2. To fully rollback: revert the git commits, re-apply the old `secrets.yaml`, and revert `secretKeyRef` key names
