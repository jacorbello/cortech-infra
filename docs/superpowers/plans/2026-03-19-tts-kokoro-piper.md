# TTS Platform (Kokoro + Piper) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Kokoro (primary) and Piper (fallback) TTS services to the K3s cluster, accessible from the LAN via NodePort.

**Architecture:** Kustomize base/overlay structure in `apps/tts/` with ArgoCD GitOps sync. Both services in a dedicated `tts` namespace. Kokoro uses upstream CPU image, Piper uses a custom image built from `piper1-gpl` and pushed to Harbor.

**Tech Stack:** Kubernetes (K3s), Kustomize, ArgoCD, Docker (Harbor registry), Kokoro-FastAPI, Piper TTS

**Spec:** `docs/superpowers/specs/2026-03-19-tts-kokoro-piper-design.md`

**Reference apps:** `apps/inference/` (GPU workload pattern), `apps/osint/` (multi-component CPU pattern)

---

## Task 1: Scaffold namespace and RBAC

**Files:**
- Create: `apps/tts/base/namespace.yaml`
- Create: `apps/tts/base/rbac/service-account.yaml`
- Create: `apps/tts/base/rbac/limit-range.yaml`
- Create: `apps/tts/base/rbac/resource-quota.yaml`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p apps/tts/base/rbac
mkdir -p apps/tts/base/kokoro
mkdir -p apps/tts/base/piper
mkdir -p apps/tts/images/piper
mkdir -p apps/tts/overlays/production
```

- [ ] **Step 2: Create namespace.yaml**

```yaml
# apps/tts/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tts
  labels:
    app.kubernetes.io/part-of: tts-platform
```

- [ ] **Step 3: Create service-account.yaml**

```yaml
# apps/tts/base/rbac/service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tts
  namespace: tts
  labels:
    app.kubernetes.io/part-of: tts-platform
```

- [ ] **Step 4: Create limit-range.yaml**

```yaml
# apps/tts/base/rbac/limit-range.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: tts-limits
  namespace: tts
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "4"
        memory: 4Gi
```

- [ ] **Step 5: Create resource-quota.yaml**

```yaml
# apps/tts/base/rbac/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tts-quota
  namespace: tts
spec:
  hard:
    requests.cpu: "4"
    limits.cpu: "8"
    requests.memory: 4Gi
    limits.memory: 8Gi
    pods: "6"
```

- [ ] **Step 6: Validate manifests with dry-run**

```bash
kubectl apply --dry-run=client -f apps/tts/base/namespace.yaml
kubectl apply --dry-run=client -f apps/tts/base/rbac/service-account.yaml
kubectl apply --dry-run=client -f apps/tts/base/rbac/limit-range.yaml
kubectl apply --dry-run=client -f apps/tts/base/rbac/resource-quota.yaml
```

Expected: all pass with `configured (dry run)` or `created (dry run)`

- [ ] **Step 7: Commit**

```bash
git add apps/tts/base/namespace.yaml apps/tts/base/rbac/
git commit -m "feat(tts): scaffold namespace and RBAC for TTS platform"
```

---

## Task 2: Kokoro deployment and service

**Files:**
- Create: `apps/tts/base/kokoro/deployment.yaml`
- Create: `apps/tts/base/kokoro/service.yaml`

- [ ] **Step 1: Create kokoro deployment.yaml**

```yaml
# apps/tts/base/kokoro/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kokoro
  namespace: tts
  labels:
    app: kokoro
    app.kubernetes.io/part-of: tts-platform
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: kokoro
  template:
    metadata:
      labels:
        app: kokoro
        app.kubernetes.io/part-of: tts-platform
    spec:
      serviceAccountName: tts
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: role
                    operator: In
                    values:
                      - core-app
                      - compute
      containers:
        - name: kokoro
          image: ghcr.io/remsky/kokoro-fastapi-cpu:v0.2.4
          ports:
            - containerPort: 8880
              name: http
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /docs
              port: http
            initialDelaySeconds: 90
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /v1/audio/voices
              port: http
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: "2"
              memory: 2Gi
```

- [ ] **Step 2: Create kokoro service.yaml**

```yaml
# apps/tts/base/kokoro/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: kokoro
  namespace: tts
  labels:
    app: kokoro
    app.kubernetes.io/part-of: tts-platform
spec:
  type: NodePort
  selector:
    app: kokoro
  ports:
    - name: http
      port: 8880
      targetPort: http
      nodePort: 30880
      protocol: TCP
```

- [ ] **Step 3: Validate with dry-run**

```bash
kubectl apply --dry-run=client -f apps/tts/base/kokoro/deployment.yaml
kubectl apply --dry-run=client -f apps/tts/base/kokoro/service.yaml
```

Expected: both pass

- [ ] **Step 4: Commit**

```bash
git add apps/tts/base/kokoro/
git commit -m "feat(tts): add Kokoro CPU deployment and NodePort service"
```

---

## Task 3: Piper Dockerfile

**Files:**
- Create: `apps/tts/images/piper/Dockerfile`

The official `piper1-gpl` Dockerfile builds from source with CMake/ninja, which is complex and slow. Since `piper-tts` is available as a pre-built wheel, our custom Dockerfile uses pip install for simplicity. Voice models are downloaded from HuggingFace at build time.

- [ ] **Step 1: Create the Piper Dockerfile**

```dockerfile
# apps/tts/images/piper/Dockerfile
FROM python:3.12-slim

ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIPER_DATA_DIR=/models

RUN apt-get update && \
    apt-get install --yes --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Install piper-tts and HTTP server dependencies
# Note: piper-tts[http] extra may not exist on PyPI, so install flask explicitly
RUN pip3 install --no-cache-dir piper-tts 'flask>=3,<4'

# Create model directories
RUN mkdir -p /models

# Download en_GB-aru-medium voice (multi-speaker)
RUN curl -L -o /models/en_GB-aru-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/aru/medium/en_GB-aru-medium.onnx" && \
    curl -L -o /models/en_GB-aru-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/aru/medium/en_GB-aru-medium.onnx.json"

# Download en_GB-northern_english_male-medium voice
RUN curl -L -o /models/en_GB-northern_english_male-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx" && \
    curl -L -o /models/en_GB-northern_english_male-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx.json"

EXPOSE 5000

ENTRYPOINT ["python3", "-m", "piper.http_server"]
CMD ["-m", "/models/en_GB-aru-medium.onnx", "--data-dir", "/models", "--host", "0.0.0.0", "--port", "5000"]
```

- [ ] **Step 2: Commit**

```bash
git add apps/tts/images/piper/Dockerfile
git commit -m "feat(tts): add Piper custom Dockerfile with British English voices"
```

---

## Task 4: Build and push Piper image to Harbor

**Prerequisites:** Harbor `tts` project must exist. This task runs on a machine with Docker access.

- [ ] **Step 1: Create Harbor project (if it doesn't exist)**

```bash
# Check if the tts project exists
curl -s -u "<user>:<pass>" https://harbor.corbello.io/api/v2.0/projects?name=tts | jq '.[].name'

# If not, create it
curl -X POST -u "<user>:<pass>" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"tts","public":true}' \
  https://harbor.corbello.io/api/v2.0/projects
```

- [ ] **Step 2: Build the image**

```bash
docker build -t harbor.corbello.io/tts/piper:1.0.0 apps/tts/images/piper/
```

Expected: successful build, image tagged

- [ ] **Step 3: Test the image locally**

```bash
docker run --rm -p 5000:5000 harbor.corbello.io/tts/piper:1.0.0 &
sleep 10

# Check voices endpoint
curl -s http://localhost:5000/voices | head -20

# Test synthesis
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"text":"Hello, this is a test of the text to speech system."}' \
  http://localhost:5000/ --output /tmp/test-tts.wav

# Verify WAV file was produced
file /tmp/test-tts.wav
# Expected: RIFF (little-endian) data, WAVE audio...

docker stop $(docker ps -q --filter ancestor=harbor.corbello.io/tts/piper:1.0.0)
```

- [ ] **Step 4: Push to Harbor**

```bash
docker login harbor.corbello.io
docker push harbor.corbello.io/tts/piper:1.0.0
```

Expected: pushed successfully, visible in Harbor UI

---

## Task 5: Piper deployment, service, and PVC

**Files:**
- Create: `apps/tts/base/piper/deployment.yaml`
- Create: `apps/tts/base/piper/service.yaml`
- Create: `apps/tts/base/piper/pvc.yaml`

- [ ] **Step 1: Create piper PVC**

```yaml
# apps/tts/base/piper/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: piper-voices-extra
  namespace: tts
  labels:
    app: piper
    app.kubernetes.io/part-of: tts-platform
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-node3
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 2: Create piper deployment.yaml**

```yaml
# apps/tts/base/piper/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: piper
  namespace: tts
  labels:
    app: piper
    app.kubernetes.io/part-of: tts-platform
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: piper
  template:
    metadata:
      labels:
        app: piper
        app.kubernetes.io/part-of: tts-platform
    spec:
      serviceAccountName: tts
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: role
                    operator: In
                    values:
                      - core-app
                      - compute
      containers:
        - name: piper
          image: harbor.corbello.io/tts/piper:1.0.0
          ports:
            - containerPort: 5000
              name: http
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /voices
              port: http
            initialDelaySeconds: 15
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /voices
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: extra-voices
              mountPath: /models/extra
      volumes:
        - name: extra-voices
          persistentVolumeClaim:
            claimName: piper-voices-extra
```

- [ ] **Step 3: Create piper service.yaml**

```yaml
# apps/tts/base/piper/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: piper
  namespace: tts
  labels:
    app: piper
    app.kubernetes.io/part-of: tts-platform
spec:
  type: NodePort
  selector:
    app: piper
  ports:
    - name: http
      port: 5000
      targetPort: http
      nodePort: 30500
      protocol: TCP
```

- [ ] **Step 4: Validate with dry-run**

```bash
kubectl apply --dry-run=client -f apps/tts/base/piper/pvc.yaml
kubectl apply --dry-run=client -f apps/tts/base/piper/deployment.yaml
kubectl apply --dry-run=client -f apps/tts/base/piper/service.yaml
```

Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add apps/tts/base/piper/
git commit -m "feat(tts): add Piper deployment, service, and extra-voices PVC"
```

---

## Task 6: Kustomization files and ArgoCD application

**Files:**
- Create: `apps/tts/base/kustomization.yaml`
- Create: `apps/tts/overlays/production/kustomization.yaml`
- Create: `apps/tts/argocd-application.yaml`

- [ ] **Step 1: Create base kustomization.yaml**

```yaml
# apps/tts/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: tts
resources:
  - namespace.yaml
  - rbac/service-account.yaml
  - rbac/limit-range.yaml
  - rbac/resource-quota.yaml
  - kokoro/deployment.yaml
  - kokoro/service.yaml
  - piper/pvc.yaml
  - piper/deployment.yaml
  - piper/service.yaml
```

- [ ] **Step 2: Create production overlay kustomization.yaml**

```yaml
# apps/tts/overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
```

- [ ] **Step 3: Create ArgoCD application**

```yaml
# apps/tts/argocd-application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tts-platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jacorbello/cortech-infra.git
    targetRevision: main
    path: apps/tts/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: tts
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Validate Kustomize build**

```bash
kubectl kustomize apps/tts/overlays/production/
```

Expected: renders all resources (namespace, service account, limit range, resource quota, 2 deployments, 2 services, 1 PVC) with `namespace: tts`

- [ ] **Step 5: Commit**

```bash
git add apps/tts/base/kustomization.yaml apps/tts/overlays/ apps/tts/argocd-application.yaml
git commit -m "feat(tts): add Kustomize config and ArgoCD application"
```

---

## Task 7: Deploy and verify

This task runs commands on the Proxmox master (`ssh root@192.168.1.52`).

**Prerequisites:** Task 4 (Piper image pushed to Harbor), all manifests committed and pushed to `main`.

- [ ] **Step 1: Push to remote**

```bash
git push origin main
```

- [ ] **Step 2: Apply ArgoCD application**

```bash
ssh root@192.168.1.52 "kubectl apply -f https://raw.githubusercontent.com/jacorbello/cortech-infra/main/apps/tts/argocd-application.yaml"
```

Or if the repo is private:

```bash
# Copy the argocd-application.yaml to the master and apply
scp apps/tts/argocd-application.yaml root@192.168.1.52:/tmp/
ssh root@192.168.1.52 "kubectl apply -f /tmp/argocd-application.yaml"
```

- [ ] **Step 3: Wait for ArgoCD sync and verify namespace**

```bash
ssh root@192.168.1.52 "kubectl get ns tts"
ssh root@192.168.1.52 "kubectl get all -n tts"
```

Expected: namespace exists, both deployments running, both services with NodePorts

- [ ] **Step 4: Verify pods are ready**

```bash
ssh root@192.168.1.52 "kubectl get pods -n tts -o wide"
```

Expected: `kokoro-*` 1/1 Running, `piper-*` 1/1 Running, both scheduled on core-app or compute nodes

- [ ] **Step 5: Verify NodePort services**

```bash
ssh root@192.168.1.52 "kubectl get svc -n tts"
```

Expected:
- `kokoro` NodePort 8880:30880/TCP
- `piper` NodePort 5000:30500/TCP

---

## Task 8: Smoke test from LAN

Run these from the Mac Mini (or any LAN machine) to verify end-to-end access.

- [ ] **Step 1: Test Kokoro voices endpoint**

```bash
curl -s http://192.168.1.90:30880/v1/audio/voices | head -20
```

Expected: JSON response listing available Kokoro voices

- [ ] **Step 2: Test Kokoro TTS synthesis**

```bash
curl -s -X POST http://192.168.1.90:30880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Hello, this is a test of the Kokoro text to speech system.","voice":"af_bella","response_format":"mp3"}' \
  --output /tmp/kokoro-test.mp3

file /tmp/kokoro-test.mp3
# Expected: Audio file (MPEG audio or similar)
```

- [ ] **Step 3: Test Piper voices endpoint**

```bash
curl -s http://192.168.1.90:30500/voices | head -20
```

Expected: JSON listing `en_GB-aru-medium` and `en_GB-northern_english_male-medium`

- [ ] **Step 4: Test Piper TTS synthesis (aru, speaker 10)**

```bash
curl -s -X POST http://192.168.1.90:30500/ \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello, this is a test of the Piper text to speech system.","voice":"en_GB-aru-medium","speaker_id":10}' \
  --output /tmp/piper-test.wav

file /tmp/piper-test.wav
# Expected: RIFF (little-endian) data, WAVE audio...
```

- [ ] **Step 5: Test Piper northern_english_male voice**

```bash
curl -s -X POST http://192.168.1.90:30500/ \
  -H "Content-Type: application/json" \
  -d '{"text":"Good morning, this is a test of the northern English male voice.","voice":"en_GB-northern_english_male-medium"}' \
  --output /tmp/piper-north-test.wav

file /tmp/piper-north-test.wav
# Expected: RIFF (little-endian) data, WAVE audio...
```

- [ ] **Step 6: Commit any fixes and final verification**

```bash
ssh root@192.168.1.52 "kubectl get pods -n tts"
ssh root@192.168.1.52 "kubectl get events -n tts --sort-by='.lastTimestamp' | tail -10"
```

Expected: both pods Running, no warning events

---

## Troubleshooting Reference

**Kokoro pod stuck in CrashLoopBackOff:**
- Check logs: `kubectl logs -n tts deploy/kokoro`
- Model loading can take 60-90s on CPU — wait for readiness probe timeout before investigating
- If OOM killed, increase memory limit in deployment

**Piper image pull fails:**
- Verify Harbor project exists: `curl -s https://harbor.corbello.io/api/v2.0/projects?name=tts`
- Verify image tag: `curl -s https://harbor.corbello.io/v2/tts/piper/tags/list`
- Check imagePullSecrets if Harbor project is private

**NodePort not reachable from LAN:**
- Verify service: `kubectl get svc -n tts`
- Test from inside cluster: `kubectl run -n tts test --rm -it --image=curlimages/curl -- curl http://kokoro:8880/docs`
- Check kube-proxy: `kubectl logs -n kube-system -l app=kube-proxy | tail -20`

**Voice model not found (Piper):**
- Check models exist in container: `kubectl exec -n tts deploy/piper -- ls -la /models/`
- Check data-dir flag in process: `kubectl exec -n tts deploy/piper -- ps aux`
