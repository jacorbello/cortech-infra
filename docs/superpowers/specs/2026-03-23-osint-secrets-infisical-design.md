# Migrate osint-secrets to Infisical Secrets Operator

**Date:** 2026-03-23
**Status:** Approved
**PR:** #6 (fix/osint-worker-digest-queue)

## Problem

The `osint-secrets` Kubernetes Secret is committed as plaintext `stringData` in `apps/osint/base/secrets.yaml`, violating the project's "never commit secrets" policy. Adding ACLED credentials compounds the issue. Secrets should be managed externally and synced into K8s automatically.

## Decision

Install the **Infisical Secrets Operator** (Infisical's native K8s operator) and use an `InfisicalSecret` CR to sync secrets from Infisical into a managed `osint-secrets` K8s Secret. This replaces the plaintext `secrets.yaml`.

### Why Infisical Operator over alternatives

- **ExternalSecrets Operator (ESO):** Heavier, provider-agnostic. Overkill for a homelab already committed to Infisical.
- **Init container with `infisical` CLI:** Brittle, couples pod startup to Infisical availability, no auto-rotation.
- **SOPS:** Encrypts at rest in git but doesn't provide rotation or centralized management.

## Architecture

### Components

1. **Infisical Secrets Operator** -- Helm chart (`infisical-helm-charts/infisical-operator`) deployed to `infisical-operator` namespace, managed by ArgoCD.

2. **Bootstrap secret** -- One-time `kubectl apply` of machine identity credentials (`clientId` + `clientSecret`) into `infisical-operator` namespace. Not committed to git.

3. **InfisicalSecret CR** -- Deployed in `osint` namespace, references the bootstrap secret cross-namespace, creates the managed `osint-secrets` K8s Secret.

4. **Infisical `/osint` folder** -- Dedicated folder in the `prod` environment scoped to osint's 6 secrets. Secrets are copied (not moved) from root to avoid breaking other consumers.

### Data Flow

```
Infisical (prod, /osint folder)
    |
    | (Universal Auth, machine identity)
    v
Infisical Secrets Operator (infisical-operator namespace)
    |
    | (creates/syncs every 60s)
    v
K8s Secret "osint-secrets" (osint namespace)
    |
    | (secretKeyRef in env vars)
    v
osint-worker, osint-beat, osint-core deployments
```

### Secret Key Mapping

Infisical stores secrets with uppercase names. The deployments' `secretKeyRef.key` values must be updated to match.

| Infisical Key | Old K8s Secret Key | Used By |
|---|---|---|
| `REDIS_PASSWORD` | `redis-password` | (not directly referenced) |
| `REDIS_URL` | `redis-url` | worker, beat, core |
| `CELERY_BROKER_URL` | `celery-broker-url` | worker, beat, core |
| `CELERY_RESULT_BACKEND` | `celery-result-backend` | worker, beat, core |
| `ACLED_EMAIL` | `acled-email` | worker, beat |
| `ACLED_PASSWORD` | `acled-password` | worker, beat |

## Implementation

### 1. Infisical setup (manual, one-time)

- Create `/osint` folder in Infisical `prod` environment
- Copy 6 secrets into it: `REDIS_PASSWORD`, `REDIS_URL`, `CELERY_BROKER_URL`, `CELERY_RESULT_BACKEND`, `ACLED_EMAIL`, `ACLED_PASSWORD`

### 2. Operator install (ArgoCD-managed)

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
    targetRevision: "*"
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

### 3. Bootstrap secret (manual kubectl apply)

```bash
kubectl create namespace infisical-operator
kubectl -n infisical-operator create secret generic infisical-machine-identity \
  --from-literal=clientId="d091297e-9918-480a-812f-1eef7ef96cab" \
  --from-literal=clientSecret="<client-secret>"
```

### 4. InfisicalSecret CR

Replace `apps/osint/base/secrets.yaml` with:

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

### 5. Update deployment secretKeyRef keys

In `osint-worker`, `osint-beat`, and `osint-core` deployments, update all `secretKeyRef.key` values from lowercase-hyphenated to uppercase Infisical names:

- `redis-url` -> `REDIS_URL`
- `celery-broker-url` -> `CELERY_BROKER_URL`
- `celery-result-backend` -> `CELERY_RESULT_BACKEND`
- `acled-email` -> `ACLED_EMAIL`
- `acled-password` -> `ACLED_PASSWORD`

### 6. Cleanup

- Delete the old plaintext `apps/osint/base/secrets.yaml` (replaced by InfisicalSecret CR)
- Add `.infisical.json` to `.gitignore`
- Update `apps/osint/base/kustomization.yaml` to reference the new file

## Rollback

If the operator fails to sync secrets:

1. The `creationPolicy: Orphan` means the managed K8s Secret persists even if the `InfisicalSecret` CR is deleted
2. Worst case: re-apply the old plaintext `secrets.yaml` and revert `secretKeyRef` key names

## Risk

- **Low:** Operator CRDs not installed when ArgoCD tries to sync the `InfisicalSecret` CR. Mitigation: deploy operator first, then the osint changes.
- **Low:** Infisical service downtime. Mitigation: `resyncInterval: 60` means the last-synced K8s Secret remains valid. Pods don't depend on Infisical at runtime.

## Future Work

- Migrate other namespaces' secrets to Infisical (harbor, argocd, etc.) using the same pattern with dedicated `/namespace` folders
- Rotate credentials that were previously committed in plaintext git history
