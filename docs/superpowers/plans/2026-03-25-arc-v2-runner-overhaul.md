# ARC v2 Runner Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix recurring ARC v2 runner failures (evictions, ghost runners, label misrouting, stale registrations) by applying best practices across all 6 runner scale sets and the controller.

**Architecture:** Update all Helm values files in `k8s/arc-v2/`, upgrade the controller with tuned settings, switch from PAT to GitHub App auth, fix one external workflow, and clean up ghost runners via GitHub API.

**Tech Stack:** Helm (gha-runner-scale-set 0.14.0, gha-runner-scale-set-controller 0.14.0), K3s, GitHub API, kubectl

**Spec:** `docs/superpowers/specs/2026-03-25-arc-v2-runner-overhaul-design.md`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `k8s/arc-v2/plotlens-runner-values.yaml` | Modify | Labels, auth, resources, graceful termination |
| `k8s/arc-v2/jarvis-runner-values.yaml` | Modify | Labels, auth, resources, nodeSelector, imagePullSecrets, graceful termination |
| `k8s/arc-v2/jarvis-runner-batch-values.yaml` | Modify | Labels, auth, resources, imagePullSecrets, graceful termination |
| `k8s/arc-v2/cortech-infra-runner-values.yaml` | Modify | Labels, auth, resources, nodeSelector, hostAliases, imagePullSecrets, graceful termination |
| `k8s/arc-v2/moltbot-trading-runner-values.yaml` | Modify | Labels, auth, resources, nodeSelector, imagePullSecrets, graceful termination |
| `k8s/arc-v2/osint-core-runner-values.yaml` | Modify | Labels, auth, resources, nodeSelector, imagePullSecrets, graceful termination |
| `k8s/arc-v2/controller-values.yaml` | Create | Controller helm values (currently using all defaults) |
| `~/repos/personal/osint-core/.github/workflows/build-base-images.yml` | Modify (external repo) | Fix `runs-on: self-hosted` → `runs-on: osint-core-runner` |

---

### Task 1: Fix osint-core workflow label (pre-requisite)

**Files:**
- Modify: `~/repos/personal/osint-core/.github/workflows/build-base-images.yml:16`

This must happen BEFORE label cleanup in Task 3+, otherwise the workflow loses its runner match.

- [ ] **Step 1: Fix the runs-on label**

In `~/repos/personal/osint-core/.github/workflows/build-base-images.yml`, change line 16:
```yaml
# Before
    runs-on: self-hosted

# After
    runs-on: osint-core-runner
```

- [ ] **Step 2: Commit and push in the osint-core repo**

```bash
cd ~/repos/personal/osint-core
git add .github/workflows/build-base-images.yml
git commit -m "fix: use osint-core-runner label instead of self-hosted

self-hosted is not routable in ARC v2 — jobs must target the
runnerScaleSetName directly."
git push origin main
```

- [ ] **Step 3: Verify the workflow file is correct on GitHub**

```bash
cd ~/repos/personal/osint-core
gh api repos/jacorbello/osint-core/contents/.github/workflows/build-base-images.yml \
  --jq '.content' | base64 -d | grep runs-on
```

Expected: `runs-on: osint-core-runner`

---

### Task 2: Create GitHub App and Kubernetes secrets (manual + CLI)

**Files:**
- No files modified in this repo — Kubernetes secrets created on cluster

This task requires manual browser steps to create the GitHub App, then CLI to create secrets.

- [ ] **Step 1: Create GitHub App in browser**

Go to https://github.com/settings/apps/new and create an app with:
- **Name:** `cortech-arc-runners` (or similar unique name)
- **Homepage URL:** `https://github.com/jacorbello/cortech-infra`
- **Webhook:** Uncheck "Active" (not needed)
- **Permissions:**
  - Repository: `Actions: Read-only`, `Metadata: Read-only`
  - Organization: `Self-hosted runners: Read and write`
- **Where can this app be installed?:** "Only on this account"
- Click "Create GitHub App"

Note the **App ID** from the app settings page.

- [ ] **Step 2: Generate a private key**

On the app settings page, scroll to "Private keys" and click "Generate a private key". Save the downloaded `.pem` file.

- [ ] **Step 3: Install the app on jacorbello account**

Go to the app's "Install App" tab → Install on `jacorbello` → Select repositories: `cortech-infra`, `jarvis`, `moltbot-trading`, `osint-core`.

Note the **Installation ID** from the URL after installation (e.g., `https://github.com/settings/installations/XXXXX`).

- [ ] **Step 4: Install the app on Family-Friendly-Inc org**

Go to the app's "Install App" tab → Install on `Family-Friendly-Inc` → Select repositories: `plotlens`.

Note the **Installation ID** (different from step 3).

- [ ] **Step 5: Copy PEM file to cluster master**

```bash
scp /path/to/downloaded-private-key.pem root@192.168.1.52:/tmp/arc-app-key.pem
```

Replace `/path/to/downloaded-private-key.pem` with the actual download path from Step 2.

- [ ] **Step 6: Create Kubernetes secret for jacorbello repos**

```bash
ssh root@192.168.1.52 "kubectl create secret generic arc-github-app-jacorbello \
  --namespace=arc-runners \
  --from-literal=github_app_id='APP_ID_HERE' \
  --from-literal=github_app_installation_id='JACORBELLO_INSTALLATION_ID_HERE' \
  --from-file=github_app_private_key=/tmp/arc-app-key.pem"
```

Replace `APP_ID_HERE` and `JACORBELLO_INSTALLATION_ID_HERE` with actual values from Steps 1 and 3.

- [ ] **Step 7: Create Kubernetes secret for Family-Friendly-Inc repos**

```bash
ssh root@192.168.1.52 "kubectl create secret generic arc-github-app-fff \
  --namespace=arc-runners \
  --from-literal=github_app_id='APP_ID_HERE' \
  --from-literal=github_app_installation_id='FFF_INSTALLATION_ID_HERE' \
  --from-file=github_app_private_key=/tmp/arc-app-key.pem"
```

Same App ID, different Installation ID from Step 4.

- [ ] **Step 8: Clean up PEM file from cluster**

```bash
ssh root@192.168.1.52 "rm -f /tmp/arc-app-key.pem"
```

- [ ] **Step 9: Verify secrets exist**

```bash
ssh root@192.168.1.52 "kubectl get secret arc-github-app-jacorbello -n arc-runners -o json | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)[\"data\"].keys()))'"
```

Expected: `['github_app_id', 'github_app_installation_id', 'github_app_private_key']`

Repeat for `arc-github-app-fff`.

---

### Task 3: Create controller values file and upgrade controller

**Files:**
- Create: `k8s/arc-v2/controller-values.yaml`

- [ ] **Step 1: Create the controller values file**

Create `k8s/arc-v2/controller-values.yaml`:
```yaml
flags:
  logLevel: "info"
  runnerMaxConcurrentReconciles: 5
  updateStrategy: "eventual"

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

- [ ] **Step 2: Upgrade the controller**

```bash
ssh root@192.168.1.52 "helm upgrade arc-v2 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.14.0 \
  --namespace arc-systems \
  --values /dev/stdin" < k8s/arc-v2/controller-values.yaml
```

- [ ] **Step 3: Verify controller is running with new config**

```bash
ssh root@192.168.1.52 "kubectl get pods -n arc-systems -l app.kubernetes.io/name=gha-rs-controller -o wide"
```

Expected: 1 pod Running, 0 restarts.

```bash
ssh root@192.168.1.52 "kubectl get pod -n arc-systems -l app.kubernetes.io/name=gha-rs-controller -o jsonpath='{.items[0].spec.containers[0].resources}'"
```

Expected: Shows the new resource requests/limits.

```bash
ssh root@192.168.1.52 "kubectl get pod -n arc-systems -l app.kubernetes.io/name=gha-rs-controller -o jsonpath='{.items[0].spec.containers[0].args}'"
```

Expected: Should contain `--update-strategy=eventual`, `--log-level=info`, and `--max-concurrent-reconciles-for-ephemeral-runner=5` (or equivalent flag names).

- [ ] **Step 4: Commit the controller values file**

```bash
git add k8s/arc-v2/controller-values.yaml
git commit -m "feat: add controller values with tuned settings

- updateStrategy: eventual (prevents orphaned runners during upgrades)
- runnerMaxConcurrentReconciles: 5 (faster cleanup)
- logLevel: info (reduce noise from debug)
- resource limits to prevent controller eviction"
```

---

### Task 4: Update plotlens-runner values

**Files:**
- Modify: `k8s/arc-v2/plotlens-runner-values.yaml`

- [ ] **Step 1: Rewrite the full values file**

Replace the entire content of `k8s/arc-v2/plotlens-runner-values.yaml`:
```yaml
githubConfigUrl: "https://github.com/Family-Friendly-Inc/plotlens"

githubConfigSecret: arc-github-app-fff

runnerScaleSetName: "plotlens-runner"

scaleSetLabels:
  - "plotlens-runner"

minRunners: 3
maxRunners: 10

containerMode:
  type: "dind"

template:
  spec:
    terminationGracePeriodSeconds: 30
    nodeSelector:
      node-type: worker
    imagePullSecrets:
      - name: harbor-registry
    tolerations:
      - effect: NoSchedule
        key: node.kubernetes.io/lifecycle
        operator: Equal
        value: ephemeral
    hostAliases:
      - hostnames:
          - harbor.corbello.io
        ip: 192.168.1.100
    initContainers:
      - name: install-kubectl
        image: curlimages/curl:8.5.0
        command:
          - sh
          - -c
          - |
            set -euo pipefail
            KUBECTL_VERSION="v1.31.0"
            BASE_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64"
            curl -fL --retry 3 --retry-delay 5 -o kubectl "${BASE_URL}/kubectl"
            curl -fL --retry 3 --retry-delay 5 -o kubectl.sha256 "${BASE_URL}/kubectl.sha256"
            echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
            chmod +x kubectl
            mv kubectl /tools/kubectl
        volumeMounts:
          - name: tools
            mountPath: /tools
    containers:
      - name: runner
        image: harbor.corbello.io/arc/plotlens-runner:v1
        command: ["/home/runner/run.sh"]
        env:
          - name: RUNNER_GRACEFUL_STOP_TIMEOUT
            value: "15"
        resources:
          requests:
            cpu: "1"
            memory: 3Gi
            ephemeral-storage: 2Gi
          limits:
            cpu: "4"
            memory: 12Gi
            ephemeral-storage: 20Gi
        volumeMounts:
          - name: tools
            mountPath: /usr/local/bin/kubectl
            subPath: kubectl
    volumes:
      - name: tools
        emptyDir: {}

controllerServiceAccount:
  namespace: arc-systems
  name: arc-v2-gha-rs-controller
```

Changes: auth → GitHub App (arc-github-app-fff), labels trimmed, `nodeSelector` added, `terminationGracePeriodSeconds: 30` added, `RUNNER_GRACEFUL_STOP_TIMEOUT` env added, `ephemeral-storage` request 1Gi → 2Gi, `ephemeral-storage` limit 4Gi → 20Gi.

- [ ] **Step 4: Helm upgrade plotlens-runner**

```bash
ssh root@192.168.1.52 "helm upgrade plotlens-runner \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.0 \
  --namespace arc-runners \
  --values /dev/stdin" < k8s/arc-v2/plotlens-runner-values.yaml
```

- [ ] **Step 5: Verify listener and runners come up**

```bash
ssh root@192.168.1.52 "kubectl get pods -n arc-systems -l actions.github.com/scale-set-name=plotlens-runner"
ssh root@192.168.1.52 "kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=plotlens-runner"
```

Expected: 1 listener pod Running in arc-systems, 3 runner pods (minRunners) in arc-runners.

- [ ] **Step 6: Commit**

```bash
git add k8s/arc-v2/plotlens-runner-values.yaml
git commit -m "fix: plotlens-runner — GitHub App auth, label cleanup, storage bump

- Switch from PAT to GitHub App (arc-github-app-fff)
- Remove redundant self-hosted/linux labels
- Bump ephemeral-storage limit 4Gi → 20Gi (prevents DinD evictions)
- Add nodeSelector, terminationGracePeriodSeconds, RUNNER_GRACEFUL_STOP_TIMEOUT"
```

---

### Task 5: Update jarvis-runner values

**Files:**
- Modify: `k8s/arc-v2/jarvis-runner-values.yaml`

- [ ] **Step 1: Rewrite the full values file**

Replace the entire content of `k8s/arc-v2/jarvis-runner-values.yaml`:
```yaml
githubConfigUrl: "https://github.com/jacorbello/jarvis"

githubConfigSecret: arc-github-app-jacorbello

runnerScaleSetName: "jarvis-runner"

scaleSetLabels:
  - "jarvis-runner"

minRunners: 2
maxRunners: 5

containerMode:
  type: "dind"

template:
  spec:
    terminationGracePeriodSeconds: 30
    nodeSelector:
      node-type: worker
    imagePullSecrets:
      - name: harbor-registry
    hostAliases:
      - hostnames:
          - harbor.corbello.io
        ip: 192.168.1.100
    initContainers:
      - name: install-kubectl
        image: curlimages/curl:8.5.0
        command:
          - sh
          - -c
          - |
            set -euo pipefail
            KUBECTL_VERSION="v1.31.0"
            BASE_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64"
            curl -fL --retry 3 --retry-delay 5 -o kubectl "${BASE_URL}/kubectl"
            curl -fL --retry 3 --retry-delay 5 -o kubectl.sha256 "${BASE_URL}/kubectl.sha256"
            echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
            chmod +x kubectl
            mv kubectl /tools/kubectl
        volumeMounts:
          - name: tools
            mountPath: /tools
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: RUNNER_GRACEFUL_STOP_TIMEOUT
            value: "15"
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
            ephemeral-storage: 1Gi
          limits:
            cpu: "1"
            memory: 2Gi
            ephemeral-storage: 10Gi
        volumeMounts:
          - name: tools
            mountPath: /usr/local/bin/kubectl
            subPath: kubectl
    volumes:
      - name: tools
        emptyDir: {}

controllerServiceAccount:
  namespace: arc-systems
  name: arc-v2-gha-rs-controller
```

Changes: auth → GitHub App, labels trimmed, `nodeSelector` added, `imagePullSecrets` added, `terminationGracePeriodSeconds` added, `RUNNER_GRACEFUL_STOP_TIMEOUT` added, memory 256Mi/1Gi → 512Mi/2Gi, ephemeral-storage 4Gi → 10Gi.

- [ ] **Step 2: Helm upgrade jarvis-runner**

```bash
ssh root@192.168.1.52 "helm upgrade jarvis-runner \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.0 \
  --namespace arc-runners \
  --values /dev/stdin" < k8s/arc-v2/jarvis-runner-values.yaml
```

- [ ] **Step 3: Verify listener and runners**

```bash
ssh root@192.168.1.52 "kubectl get pods -n arc-systems -l actions.github.com/scale-set-name=jarvis-runner"
ssh root@192.168.1.52 "kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=jarvis-runner"
```

Expected: 1 listener Running, 2 runner pods (minRunners).

- [ ] **Step 4: Commit**

```bash
git add k8s/arc-v2/jarvis-runner-values.yaml
git commit -m "fix: jarvis-runner — GitHub App auth, labels, resources, nodeSelector

- Switch from PAT to GitHub App (arc-github-app-jacorbello)
- Remove redundant self-hosted/linux labels
- Add nodeSelector, imagePullSecrets, terminationGracePeriodSeconds
- Bump memory 256Mi/1Gi → 512Mi/2Gi, ephemeral 4Gi → 10Gi"
```

---

### Task 6: Update jarvis-runner-batch values

**Files:**
- Modify: `k8s/arc-v2/jarvis-runner-batch-values.yaml`

- [ ] **Step 1: Rewrite the full values file**

Replace the entire content of `k8s/arc-v2/jarvis-runner-batch-values.yaml`:
```yaml
githubConfigUrl: "https://github.com/jacorbello/jarvis"

githubConfigSecret: arc-github-app-jacorbello

runnerScaleSetName: "jarvis-runner-batch"

scaleSetLabels:
  - "jarvis-runner-batch"

minRunners: 1
maxRunners: 4

containerMode:
  type: "dind"

template:
  spec:
    terminationGracePeriodSeconds: 30
    nodeSelector:
      role: batch-compute
    imagePullSecrets:
      - name: harbor-registry
    tolerations:
      - effect: NoSchedule
        key: node.kubernetes.io/lifecycle
        operator: Equal
        value: ephemeral
    hostAliases:
      - hostnames:
          - harbor.corbello.io
        ip: 192.168.1.100
    initContainers:
      - name: install-kubectl
        image: curlimages/curl:8.5.0
        command:
          - sh
          - -c
          - |
            set -euo pipefail
            KUBECTL_VERSION="v1.31.0"
            BASE_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64"
            curl -fL --retry 3 --retry-delay 5 -o kubectl "${BASE_URL}/kubectl"
            curl -fL --retry 3 --retry-delay 5 -o kubectl.sha256 "${BASE_URL}/kubectl.sha256"
            echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
            chmod +x kubectl
            mv kubectl /tools/kubectl
        volumeMounts:
          - name: tools
            mountPath: /tools
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: RUNNER_GRACEFUL_STOP_TIMEOUT
            value: "15"
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
            ephemeral-storage: 1Gi
          limits:
            cpu: "1"
            memory: 2Gi
            ephemeral-storage: 10Gi
        volumeMounts:
          - name: tools
            mountPath: /usr/local/bin/kubectl
            subPath: kubectl
    volumes:
      - name: tools
        emptyDir: {}

controllerServiceAccount:
  namespace: arc-systems
  name: arc-v2-gha-rs-controller
```

Changes: auth → GitHub App, labels trimmed, `imagePullSecrets` added, `terminationGracePeriodSeconds` added, `RUNNER_GRACEFUL_STOP_TIMEOUT` added, memory 256Mi/1Gi → 512Mi/2Gi, ephemeral-storage 4Gi → 10Gi.

- [ ] **Step 2: Helm upgrade jarvis-runner-batch**

```bash
ssh root@192.168.1.52 "helm upgrade jarvis-runner-batch \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.0 \
  --namespace arc-runners \
  --values /dev/stdin" < k8s/arc-v2/jarvis-runner-batch-values.yaml
```

- [ ] **Step 3: Verify listener and runners**

```bash
ssh root@192.168.1.52 "kubectl get pods -n arc-systems -l actions.github.com/scale-set-name=jarvis-runner-batch"
ssh root@192.168.1.52 "kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=jarvis-runner-batch"
```

Expected: 1 listener Running, 1 runner pod (minRunners).

- [ ] **Step 4: Commit**

```bash
git add k8s/arc-v2/jarvis-runner-batch-values.yaml
git commit -m "fix: jarvis-runner-batch — GitHub App auth, labels, resources

- Switch from PAT to GitHub App (arc-github-app-jacorbello)
- Remove redundant self-hosted/linux labels
- Add imagePullSecrets, terminationGracePeriodSeconds
- Bump memory 256Mi/1Gi → 512Mi/2Gi, ephemeral 4Gi → 10Gi"
```

---

### Task 7: Update cortech-infra-runner values

**Files:**
- Modify: `k8s/arc-v2/cortech-infra-runner-values.yaml`

- [ ] **Step 1: Rewrite the full values file**

Replace the entire content of `k8s/arc-v2/cortech-infra-runner-values.yaml`:
```yaml
githubConfigUrl: "https://github.com/jacorbello/cortech-infra"

githubConfigSecret: arc-github-app-jacorbello

runnerScaleSetName: "cortech-infra-runner"

scaleSetLabels:
  - "cortech-infra-runner"

minRunners: 1
maxRunners: 3

containerMode:
  type: "dind"

template:
  spec:
    terminationGracePeriodSeconds: 30
    nodeSelector:
      node-type: worker
    imagePullSecrets:
      - name: harbor-registry
    hostAliases:
      - hostnames:
          - harbor.corbello.io
        ip: 192.168.1.100
    initContainers:
      - name: setup-ssh-keys
        image: busybox
        command:
          - sh
          - -c
          - |
            cp /secret-mount/id_ed25519 /ssh-keys/id_ed25519
            cp /secret-mount/known_hosts /ssh-keys/known_hosts
            chmod 600 /ssh-keys/id_ed25519
            chmod 644 /ssh-keys/known_hosts
            chown 1001:1001 /ssh-keys/id_ed25519 /ssh-keys/known_hosts
        volumeMounts:
          - name: proxy-ssh-key
            mountPath: /secret-mount
            readOnly: true
          - name: ssh-keys
            mountPath: /ssh-keys
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: RUNNER_GRACEFUL_STOP_TIMEOUT
            value: "15"
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
            ephemeral-storage: 1Gi
          limits:
            cpu: "1"
            memory: 2Gi
            ephemeral-storage: 10Gi
        volumeMounts:
          - name: ssh-keys
            mountPath: /ssh-keys
    volumes:
      - name: proxy-ssh-key
        secret:
          secretName: cortech-infra-proxy-ssh-key
          defaultMode: 0400
      - name: ssh-keys
        emptyDir: {}

controllerServiceAccount:
  namespace: arc-systems
  name: arc-v2-gha-rs-controller
```

Changes: auth → GitHub App, labels trimmed, `nodeSelector` added, `imagePullSecrets` added, `hostAliases` added, `terminationGracePeriodSeconds` added, `RUNNER_GRACEFUL_STOP_TIMEOUT` added, memory 256Mi/1Gi → 512Mi/2Gi, ephemeral-storage 4Gi → 10Gi.

- [ ] **Step 2: Helm upgrade cortech-infra-runner**

```bash
ssh root@192.168.1.52 "helm upgrade cortech-infra-runner \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.0 \
  --namespace arc-runners \
  --values /dev/stdin" < k8s/arc-v2/cortech-infra-runner-values.yaml
```

- [ ] **Step 3: Verify listener and runners**

```bash
ssh root@192.168.1.52 "kubectl get pods -n arc-systems -l actions.github.com/scale-set-name=cortech-infra-runner"
ssh root@192.168.1.52 "kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=cortech-infra-runner"
```

Expected: 1 listener Running, 1 runner pod (minRunners).

- [ ] **Step 4: Commit**

```bash
git add k8s/arc-v2/cortech-infra-runner-values.yaml
git commit -m "fix: cortech-infra-runner — GitHub App auth, labels, resources, hostAliases

- Switch from PAT to GitHub App (arc-github-app-jacorbello)
- Remove redundant self-hosted/linux labels
- Add nodeSelector, imagePullSecrets, hostAliases, terminationGracePeriodSeconds
- Bump memory 256Mi/1Gi → 512Mi/2Gi, ephemeral 4Gi → 10Gi"
```

---

### Task 8: Update moltbot-trading-runner values

**Files:**
- Modify: `k8s/arc-v2/moltbot-trading-runner-values.yaml`

- [ ] **Step 1: Rewrite the full values file**

Replace the entire content of `k8s/arc-v2/moltbot-trading-runner-values.yaml`:
```yaml
githubConfigUrl: "https://github.com/jacorbello/moltbot-trading"

githubConfigSecret: arc-github-app-jacorbello

runnerScaleSetName: "moltbot-trading-runner"

scaleSetLabels:
  - "moltbot-trading-runner"

minRunners: 1
maxRunners: 3

containerMode:
  type: "dind"

template:
  spec:
    terminationGracePeriodSeconds: 30
    serviceAccountName: moltbot-deployer
    nodeSelector:
      node-type: worker
    imagePullSecrets:
      - name: harbor-registry
    hostAliases:
      - hostnames:
          - harbor.corbello.io
        ip: 192.168.1.100
    initContainers:
      - name: install-kubectl
        image: curlimages/curl:8.5.0
        command:
          - sh
          - -c
          - |
            set -euo pipefail
            KUBECTL_VERSION="v1.31.0"
            BASE_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64"
            curl -fL --retry 3 --retry-delay 5 -o kubectl "${BASE_URL}/kubectl"
            curl -fL --retry 3 --retry-delay 5 -o kubectl.sha256 "${BASE_URL}/kubectl.sha256"
            echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
            chmod +x kubectl
            mv kubectl /tools/kubectl
        volumeMounts:
          - name: tools
            mountPath: /tools
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: RUNNER_GRACEFUL_STOP_TIMEOUT
            value: "15"
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
            ephemeral-storage: 1Gi
          limits:
            cpu: "1"
            memory: 2Gi
            ephemeral-storage: 10Gi
        volumeMounts:
          - name: tools
            mountPath: /usr/local/bin/kubectl
            subPath: kubectl
    volumes:
      - name: tools
        emptyDir: {}

controllerServiceAccount:
  namespace: arc-systems
  name: arc-v2-gha-rs-controller
```

Changes: auth → GitHub App, labels trimmed, `nodeSelector` added, `imagePullSecrets` added, `terminationGracePeriodSeconds` added, `RUNNER_GRACEFUL_STOP_TIMEOUT` added, memory 256Mi/1Gi → 512Mi/2Gi, ephemeral-storage 4Gi → 10Gi.

- [ ] **Step 2: Helm upgrade moltbot-trading-runner**

```bash
ssh root@192.168.1.52 "helm upgrade moltbot-trading-runner \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.0 \
  --namespace arc-runners \
  --values /dev/stdin" < k8s/arc-v2/moltbot-trading-runner-values.yaml
```

- [ ] **Step 3: Verify listener and runners**

```bash
ssh root@192.168.1.52 "kubectl get pods -n arc-systems -l actions.github.com/scale-set-name=moltbot-trading-runner"
ssh root@192.168.1.52 "kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=moltbot-trading-runner"
```

Expected: 1 listener Running, 1 runner pod (minRunners).

- [ ] **Step 4: Commit**

```bash
git add k8s/arc-v2/moltbot-trading-runner-values.yaml
git commit -m "fix: moltbot-trading-runner — GitHub App auth, labels, resources

- Switch from PAT to GitHub App (arc-github-app-jacorbello)
- Remove redundant self-hosted/linux labels
- Add nodeSelector, imagePullSecrets, terminationGracePeriodSeconds
- Bump memory 256Mi/1Gi → 512Mi/2Gi, ephemeral 4Gi → 10Gi"
```

---

### Task 9: Update osint-core-runner values

**Files:**
- Modify: `k8s/arc-v2/osint-core-runner-values.yaml`

- [ ] **Step 1: Rewrite the full values file**

Replace the entire content of `k8s/arc-v2/osint-core-runner-values.yaml`:
```yaml
githubConfigUrl: "https://github.com/jacorbello/osint-core"

githubConfigSecret: arc-github-app-jacorbello

runnerScaleSetName: "osint-core-runner"

scaleSetLabels:
  - "osint-core-runner"

minRunners: 1
maxRunners: 3

containerMode:
  type: "dind"

template:
  spec:
    terminationGracePeriodSeconds: 30
    nodeSelector:
      node-type: worker
    imagePullSecrets:
      - name: harbor-registry
    hostAliases:
      - hostnames:
          - harbor.corbello.io
        ip: 192.168.1.100
    initContainers:
      - name: install-kubectl
        image: curlimages/curl:8.5.0
        command:
          - sh
          - -c
          - |
            set -euo pipefail
            KUBECTL_VERSION="v1.31.0"
            BASE_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64"
            curl -fL --retry 3 --retry-delay 5 -o kubectl "${BASE_URL}/kubectl"
            curl -fL --retry 3 --retry-delay 5 -o kubectl.sha256 "${BASE_URL}/kubectl.sha256"
            echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
            chmod +x kubectl
            mv kubectl /tools/kubectl
        volumeMounts:
          - name: tools
            mountPath: /tools
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: RUNNER_GRACEFUL_STOP_TIMEOUT
            value: "15"
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
            ephemeral-storage: 1Gi
          limits:
            cpu: "1"
            memory: 2Gi
            ephemeral-storage: 10Gi
        volumeMounts:
          - name: tools
            mountPath: /usr/local/bin/kubectl
            subPath: kubectl
    volumes:
      - name: tools
        emptyDir: {}

controllerServiceAccount:
  namespace: arc-systems
  name: arc-v2-gha-rs-controller
```

Changes: auth → GitHub App, labels trimmed, `nodeSelector` added, `imagePullSecrets` added, `terminationGracePeriodSeconds` added, `RUNNER_GRACEFUL_STOP_TIMEOUT` added, memory 256Mi/1Gi → 512Mi/2Gi, ephemeral-storage 4Gi → 10Gi.

- [ ] **Step 2: Helm upgrade osint-core-runner**

```bash
ssh root@192.168.1.52 "helm upgrade osint-core-runner \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.0 \
  --namespace arc-runners \
  --values /dev/stdin" < k8s/arc-v2/osint-core-runner-values.yaml
```

- [ ] **Step 3: Verify listener and runners**

```bash
ssh root@192.168.1.52 "kubectl get pods -n arc-systems -l actions.github.com/scale-set-name=osint-core-runner"
ssh root@192.168.1.52 "kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=osint-core-runner"
```

Expected: 1 listener Running, 1 runner pod (minRunners).

- [ ] **Step 4: Commit**

```bash
git add k8s/arc-v2/osint-core-runner-values.yaml
git commit -m "fix: osint-core-runner — GitHub App auth, labels, resources

- Switch from PAT to GitHub App (arc-github-app-jacorbello)
- Remove redundant self-hosted/linux labels
- Add nodeSelector, imagePullSecrets, terminationGracePeriodSeconds
- Bump memory 256Mi/1Gi → 512Mi/2Gi, ephemeral 4Gi → 10Gi"
```

---

### Task 10: Purge ghost runners and verify

**Files:**
- No files modified

- [ ] **Step 1: Purge offline runners from all repos**

```bash
for repo in jacorbello/cortech-infra jacorbello/jarvis jacorbello/moltbot-trading \
            jacorbello/osint-core Family-Friendly-Inc/plotlens; do
  echo "=== ${repo} ==="
  gh api "repos/${repo}/actions/runners" --jq '.runners[] | select(.status=="offline") | "\(.id) \(.name)"'
done
```

Review the output, then delete:
```bash
for repo in jacorbello/cortech-infra jacorbello/jarvis jacorbello/moltbot-trading \
            jacorbello/osint-core Family-Friendly-Inc/plotlens; do
  gh api "repos/${repo}/actions/runners" --jq '.runners[] | select(.status=="offline") | .id' | \
    xargs -I{} gh api -X DELETE "repos/${repo}/actions/runners/{}"
done
```

- [ ] **Step 2: Check org-level runners**

```bash
gh api "orgs/Family-Friendly-Inc/actions/runners" --jq '.runners[] | select(.status=="offline") | "\(.id) \(.name)"'
```

Delete any offline ones:
```bash
gh api "orgs/Family-Friendly-Inc/actions/runners" --jq '.runners[] | select(.status=="offline") | .id' | \
  xargs -I{} gh api -X DELETE "orgs/Family-Friendly-Inc/actions/runners/{}"
```

- [ ] **Step 3: Verify labels were cleaned from all scale sets**

```bash
ssh root@192.168.1.52 "kubectl get autoscalingrunnerset -n arc-runners -o json | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data[\"items\"]:
    name = item[\"metadata\"][\"name\"]
    labels = item[\"spec\"].get(\"scaleSetLabels\", [])
    print(f\"{name}: {labels}\")
'"
```

Expected: Each scale set shows only its own name label (no `self-hosted`, no `linux`).

- [ ] **Step 4: Full environment verification**

```bash
# All listeners healthy
ssh root@192.168.1.52 "kubectl get pods -n arc-systems"

# All runners at expected counts
ssh root@192.168.1.52 "kubectl get autoscalingrunnerset -n arc-runners"

# No eviction events
ssh root@192.168.1.52 "kubectl get events -n arc-runners --field-selector reason=Evicted"

# Controller logs clean
ssh root@192.168.1.52 "kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-rs-controller --tail=50 | grep -iE 'error|fail'"

# Runner pods on correct nodes
ssh root@192.168.1.52 "kubectl get pods -n arc-runners -o wide"
```

Expected:
- 6 listeners in arc-systems, all Running
- Runner counts match minRunners (plotlens: 3, jarvis: 2, rest: 1 each)
- No Evicted events
- No errors in controller logs
- Pods on worker nodes (primarily wrk-3)

- [ ] **Step 5: Trigger test workflows on both GitHub App installations**

Test the jacorbello installation:
```bash
gh workflow run ci.yaml --repo jacorbello/osint-core
```

Test the Family-Friendly-Inc installation:
```bash
gh workflow run ci.yaml --repo Family-Friendly-Inc/plotlens --ref main
```

Watch in GitHub Actions UI — both jobs should be picked up by their respective runners within seconds. This verifies both GitHub App installation secrets work end-to-end.

---

### Task 11: Cleanup — delete old PAT secret

**Files:**
- No files modified

Only do this after Task 10 verification passes.

- [ ] **Step 1: Confirm all scale sets are using GitHub App auth**

```bash
ssh root@192.168.1.52 "for rs in plotlens-runner jarvis-runner jarvis-runner-batch cortech-infra-runner moltbot-trading-runner osint-core-runner; do
  echo -n \"\${rs}: \"
  helm get values \${rs} -n arc-runners 2>/dev/null | grep githubConfigSecret
done"
```

Expected: All show `arc-github-app-jacorbello` or `arc-github-app-fff`.

- [ ] **Step 2: Delete the old PAT secret**

```bash
ssh root@192.168.1.52 "kubectl delete secret arc-github-pat -n arc-runners"
```

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "chore: complete ARC v2 runner overhaul

All 6 scale sets migrated to GitHub App auth, labels cleaned,
resources tuned, controller upgraded. Ghost runners purged.

Spec: docs/superpowers/specs/2026-03-25-arc-v2-runner-overhaul-design.md"
```
