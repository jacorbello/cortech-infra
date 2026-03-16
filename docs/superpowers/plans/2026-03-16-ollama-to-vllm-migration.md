# Ollama to vLLM Migration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate GPU inference from Ollama (VM 205) to vLLM running as a K8s pod on a new GPU worker node, with a shared `inference` namespace accessible by multiple consumers.

**Architecture:** New VM 207 (`k3s-wrk-4`) on cortech-node3 with Tesla T4 GPU passthrough joins K3s cluster. vLLM runs as a Deployment in a new `inference` namespace. OSINT workloads switch from Ollama's `/api/generate` to vLLM's OpenAI-compatible `/v1/chat/completions`. Phased cutover with Jinja2 fallback providing safety net throughout.

**Tech Stack:** Proxmox (VM management), K3s (Kubernetes), Kustomize, ArgoCD, NVIDIA Container Toolkit, vLLM, Prometheus/Grafana

**Spec:** `docs/superpowers/specs/2026-03-16-ollama-to-vllm-migration-design.md`

---

## File Structure

### New Files (this repo)

| File | Responsibility |
|------|----------------|
| `apps/inference/argocd-application.yaml` | ArgoCD Application CR pointing at overlays/production |
| `apps/inference/base/namespace.yaml` | Namespace definition with labels |
| `apps/inference/base/kustomization.yaml` | Kustomize resource list for base |
| `apps/inference/base/rbac/service-account.yaml` | ServiceAccount for vLLM pods |
| `apps/inference/base/rbac/resource-quota.yaml` | GPU/CPU/memory quota for namespace |
| `apps/inference/base/rbac/limit-range.yaml` | Default container resource limits |
| `apps/inference/base/rbac/priority-classes.yaml` | `inference-gpu` PriorityClass (value 200) |
| `apps/inference/base/network-policies/default-deny.yaml` | Ingress rules: allow osint, jarvis, plotlens, observability, inference |
| `apps/inference/base/monitoring/service-monitor.yaml` | Prometheus ServiceMonitor for `/metrics` |
| `apps/inference/base/vllm/deployment.yaml` | vLLM Deployment with GPU resources, tolerations, probes |
| `apps/inference/base/vllm/service.yaml` | ClusterIP Service on port 8000 |
| `apps/inference/base/vllm/pvc.yaml` | 50Gi PVC on nfs-node3 for HuggingFace cache |
| `apps/inference/overlays/production/kustomization.yaml` | Production overlay (references ../../base) |
| `k8s/kube-system/nvidia-device-plugin.yaml` | NVIDIA device plugin DaemonSet |
| `k8s/observability/dashboards/applications/vllm-inference.yaml` | Grafana dashboard ConfigMap |

### Modified Files

| File | Change |
|------|--------|
| `apps/osint/base/osint-core/deployment.yaml` | Replace `OSINT_OLLAMA_URL` → `OSINT_VLLM_URL` + `OSINT_LLM_MODEL` |
| `apps/osint/base/osint-worker/deployment.yaml` | Same env var swap |
| `apps/osint/base/osint-beat/deployment.yaml` | Same env var swap |
| `apps/osint/base/kustomization.yaml` | Remove `external-services/ollama.yaml` reference |

### Deleted Files

| File | Reason |
|------|--------|
| `apps/osint/base/external-services/ollama.yaml` | Replaced by vLLM in inference namespace |

---

## Chunk 1: Inference Namespace Manifests

### Task 1: Create namespace and RBAC manifests

**Files:**
- Create: `apps/inference/base/namespace.yaml`
- Create: `apps/inference/base/rbac/service-account.yaml`
- Create: `apps/inference/base/rbac/resource-quota.yaml`
- Create: `apps/inference/base/rbac/limit-range.yaml`
- Create: `apps/inference/base/rbac/priority-classes.yaml`

**Reference:** Follow patterns from `apps/osint/base/namespace.yaml` and `apps/osint/base/rbac/` files.

- [ ] **Step 1: Create namespace manifest**

Create `apps/inference/base/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: inference
  labels:
    app.kubernetes.io/part-of: inference-platform
```

- [ ] **Step 2: Create service account**

Create `apps/inference/base/rbac/service-account.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vllm
  namespace: inference
  labels:
    app.kubernetes.io/part-of: inference-platform
```

- [ ] **Step 3: Create resource quota**

Create `apps/inference/base/rbac/resource-quota.yaml`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: inference-quota
  namespace: inference
spec:
  hard:
    requests.cpu: "8"
    limits.cpu: "16"
    requests.memory: 20Gi
    limits.memory: 20Gi
    requests.nvidia.com/gpu: "1"
    limits.nvidia.com/gpu: "1"
    pods: "4"
```

- [ ] **Step 4: Create limit range**

Create `apps/inference/base/rbac/limit-range.yaml`:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: inference-limits
  namespace: inference
spec:
  limits:
    - type: Container
      default:
        cpu: "2"
        memory: 4Gi
      defaultRequest:
        cpu: "1"
        memory: 2Gi
      max:
        cpu: "8"
        memory: 12Gi
```

- [ ] **Step 5: Create priority class**

Create `apps/inference/base/rbac/priority-classes.yaml`:

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: inference-gpu
value: 200
globalDefault: false
description: "Priority class for GPU inference workloads (expensive to restart, slow to load models)"
```

- [ ] **Step 6: Validate YAML syntax**

Run: `yamllint apps/inference/base/namespace.yaml apps/inference/base/rbac/`
Expected: No errors (warnings about line length are OK)

- [ ] **Step 7: Commit**

```bash
git add apps/inference/base/namespace.yaml apps/inference/base/rbac/
git commit -m "feat(inference): add namespace and RBAC manifests"
```

---

### Task 2: Create network policy

**Files:**
- Create: `apps/inference/base/network-policies/default-deny.yaml`

**Reference:** Follow pattern from `apps/osint/base/network-policies/default-deny.yaml`.

- [ ] **Step 1: Create network policy manifest**

Create `apps/inference/base/network-policies/default-deny.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: inference
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: inference
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: osint
      ports:
        - protocol: TCP
          port: 8000
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: jarvis
      ports:
        - protocol: TCP
          port: 8000
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: plotlens
      ports:
        - protocol: TCP
          port: 8000
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 8000
```

- [ ] **Step 2: Validate YAML**

Run: `yamllint apps/inference/base/network-policies/default-deny.yaml`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add apps/inference/base/network-policies/
git commit -m "feat(inference): add network policy allowing osint, jarvis, plotlens, observability"
```

---

### Task 3: Create vLLM deployment, service, and PVC

**Files:**
- Create: `apps/inference/base/vllm/deployment.yaml`
- Create: `apps/inference/base/vllm/service.yaml`
- Create: `apps/inference/base/vllm/pvc.yaml`

**Reference:** Follow patterns from `apps/osint/base/osint-core/deployment.yaml`, `apps/osint/base/osint-core/service.yaml`, `apps/osint/base/qdrant/pvc.yaml`.

- [ ] **Step 1: Create PVC manifest**

Create `apps/inference/base/vllm/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vllm-model-cache
  namespace: inference
  labels:
    app: vllm
    app.kubernetes.io/part-of: inference-platform
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-node3
  resources:
    requests:
      storage: 50Gi
```

- [ ] **Step 2: Create service manifest**

Create `apps/inference/base/vllm/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vllm
  namespace: inference
  labels:
    app: vllm
    app.kubernetes.io/part-of: inference-platform
spec:
  type: ClusterIP
  selector:
    app: vllm
  ports:
    - port: 8000
      targetPort: http
      protocol: TCP
      name: http
```

- [ ] **Step 3: Create deployment manifest**

**Before writing this file:** Look up the latest stable vLLM release tag at https://hub.docker.com/r/vllm/vllm-openai/tags and replace `<pinned-tag>` below with the actual tag (e.g., `v0.8.5`). Do NOT commit the literal `<pinned-tag>` string.

Create `apps/inference/base/vllm/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  namespace: inference
  labels:
    app: vllm
    app.kubernetes.io/part-of: inference-platform
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
        app.kubernetes.io/part-of: inference-platform
    spec:
      serviceAccountName: vllm
      priorityClassName: inference-gpu
      nodeSelector:
        role: gpu-inference
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "present"
          effect: NoSchedule
      volumes:
        - name: model-cache
          persistentVolumeClaim:
            claimName: vllm-model-cache
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
      containers:
        - name: vllm
          image: vllm/vllm-openai:<pinned-tag>
          command: ["/bin/sh", "-c"]
          args:
            - >-
              vllm serve meta-llama/Llama-3.2-3B-Instruct
              --dtype float16
              --max-model-len 8192
              --gpu-memory-utilization 0.85
              --enable-prefix-caching
              --port 8000
          env:
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token-secret
                  key: token
          ports:
            - containerPort: 8000
              name: http
              protocol: TCP
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
              nvidia.com/gpu: "1"
            limits:
              cpu: "4"
              memory: 8Gi
              nvidia.com/gpu: "1"
          volumeMounts:
            - name: model-cache
              mountPath: /root/.cache/huggingface
            - name: shm
              mountPath: /dev/shm
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 120
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 120
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 3
```

- [ ] **Step 4: Verify no placeholder tag remains**

Run: `grep '<pinned-tag>' apps/inference/base/vllm/deployment.yaml`
Expected: No output (no matches). If it matches, go back and replace with the actual tag.

- [ ] **Step 5: Validate YAML**

Run: `yamllint apps/inference/base/vllm/`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add apps/inference/base/vllm/
git commit -m "feat(inference): add vLLM deployment, service, and PVC manifests"
```

---

### Task 4: Create ServiceMonitor for Prometheus

**Files:**
- Create: `apps/inference/base/monitoring/service-monitor.yaml`

**Reference:** Follow pattern from `apps/osint/base/monitoring/service-monitor.yaml`.

- [ ] **Step 1: Create ServiceMonitor manifest**

Create `apps/inference/base/monitoring/service-monitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm
  namespace: inference
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: vllm
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

- [ ] **Step 2: Validate YAML**

Run: `yamllint apps/inference/base/monitoring/service-monitor.yaml`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add apps/inference/base/monitoring/
git commit -m "feat(inference): add Prometheus ServiceMonitor for vLLM metrics"
```

---

### Task 5: Create Kustomization, overlay, and ArgoCD application

**Files:**
- Create: `apps/inference/base/kustomization.yaml`
- Create: `apps/inference/overlays/production/kustomization.yaml`
- Create: `apps/inference/argocd-application.yaml`

**Reference:** Follow patterns from `apps/osint/base/kustomization.yaml`, `apps/osint/overlays/production/kustomization.yaml`, `apps/osint/argocd-application.yaml`.

- [ ] **Step 1: Create base kustomization**

Create `apps/inference/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: inference
resources:
  - namespace.yaml
  - rbac/resource-quota.yaml
  - rbac/limit-range.yaml
  - rbac/priority-classes.yaml
  - rbac/service-account.yaml
  - network-policies/default-deny.yaml
  - vllm/pvc.yaml
  - vllm/service.yaml
  - vllm/deployment.yaml
  - monitoring/service-monitor.yaml
```

- [ ] **Step 2: Create production overlay**

Create `apps/inference/overlays/production/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
```

- [ ] **Step 3: Create ArgoCD application**

Create `apps/inference/argocd-application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: inference-platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jacorbello/cortech-infra.git
    targetRevision: main
    path: apps/inference/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: inference
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Validate Kustomize build**

Run: `kustomize build apps/inference/overlays/production`
Expected: All resources rendered correctly, no errors. Verify the output includes namespace, RBAC, network policy, deployment, service, PVC, and ServiceMonitor.

- [ ] **Step 5: Commit**

```bash
git add apps/inference/base/kustomization.yaml apps/inference/overlays/ apps/inference/argocd-application.yaml
git commit -m "feat(inference): add Kustomize base/overlay and ArgoCD application"
```

---

## Chunk 2: NVIDIA Device Plugin and GPU Node Setup

### Task 6: Create NVIDIA device plugin DaemonSet manifest

**Files:**
- Create: `k8s/kube-system/nvidia-device-plugin.yaml`

- [ ] **Step 1: Create device plugin manifest**

Create `k8s/kube-system/nvidia-device-plugin.yaml`:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin
  namespace: kube-system
  labels:
    app: nvidia-device-plugin
spec:
  selector:
    matchLabels:
      app: nvidia-device-plugin
  template:
    metadata:
      labels:
        app: nvidia-device-plugin
    spec:
      nodeSelector:
        gpu: tesla-t4
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      priorityClassName: system-node-critical
      containers:
        - name: nvidia-device-plugin
          image: nvcr.io/nvidia/k8s-device-plugin:v0.17.0
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
```

- [ ] **Step 2: Validate YAML**

Run: `yamllint k8s/kube-system/nvidia-device-plugin.yaml`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add k8s/kube-system/nvidia-device-plugin.yaml
git commit -m "feat(kube-system): add NVIDIA device plugin DaemonSet for GPU nodes"
```

---

### Task 7: Provision VM 207 on cortech-node3

**Prerequisites:**
- SSH access to cortech-node3 (`ssh root@192.168.1.114`)
- Ubuntu 22.04 cloud image available (or matching existing K3s nodes)
- K3s join token from the cluster

**Note:** This task involves Proxmox CLI commands run on the hypervisor. It cannot be done from this repo — it's an operational task.

- [ ] **Step 1: Download Ubuntu cloud image (if not already available)**

SSH into cortech-node3:
```bash
ssh root@192.168.1.114
# Check existing images
ls /var/lib/vz/template/iso/
# Download if needed (use same version as existing K3s nodes)
```

- [ ] **Step 2: Create VM 207 with q35/OVMF**

On cortech-node3:
```bash
qm create 207 \
  --name k3s-wrk-4 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 storage-pool:1,efitype=4m \
  --cpu host \
  --cores 16 \
  --sockets 1 \
  --memory 32768 \
  --balloon 0 \
  --net0 virtio,bridge=vmbr0 \
  --scsi0 storage-pool:100,discard=on,iothread=1 \
  --scsihw virtio-scsi-single \
  --ostype l26 \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --ciuser k3s \
  --ipconfig0 ip=192.168.1.98/24,gw=192.168.1.1 \
  --nameserver 192.168.1.1 \
  --searchdomain corbello.io
```

Add SSH keys (match existing K3s nodes):
```bash
qm set 207 --sshkeys /path/to/authorized_keys
```

- [ ] **Step 3: Import cloud image as boot disk**

```bash
# Import the cloud image into the VM's disk
qm importdisk 207 /var/lib/vz/template/iso/ubuntu-22.04-server-cloudimg-amd64.img storage-pool
qm set 207 --scsi0 storage-pool:vm-207-disk-0,discard=on,iothread=1,size=100G
qm set 207 --boot order=scsi0
qm set 207 --ide2 storage-pool:cloudinit,media=cdrom
```

- [ ] **Step 4: Start VM 207 (without GPU initially)**

```bash
qm start 207
# Wait for cloud-init to complete
ssh k3s@192.168.1.98 "cloud-init status --wait"
```

- [ ] **Step 5: Verify disk size and filesystem**

```bash
ssh k3s@192.168.1.98 "df -h /"
```

Expected: ~98G available. Cloud-init should auto-expand the partition on first boot. If the filesystem is still small (~2G), manually expand:
```bash
ssh k3s@192.168.1.98 "sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1"
```

- [ ] **Step 6: Install NVIDIA drivers on VM 207**

SSH into VM 207:
```bash
ssh k3s@192.168.1.98
sudo apt update && sudo apt install -y nvidia-driver-550-server
sudo reboot
```

After reboot, verify driver installed:
```bash
ssh k3s@192.168.1.98 "dpkg -l | grep nvidia-driver-550"
```

Expected: Package listed as installed (`ii` status). Running `nvidia-smi` will report "no devices found" because the GPU is not yet passed through — this is normal at this stage.

- [ ] **Step 7: Install NVIDIA Container Toolkit on VM 207**

SSH into VM 207:
```bash
ssh k3s@192.168.1.98

# Add NVIDIA container toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update && sudo apt install -y nvidia-container-toolkit

# Configure containerd (K3s uses containerd)
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

- [ ] **Step 8: Join K3s cluster**

Get the join token from the master:
```bash
ssh root@192.168.1.52 "cat /var/lib/rancher/k3s/server/node-token"
```

On VM 207:
```bash
ssh k3s@192.168.1.98
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.90:6443 K3S_TOKEN=<token> sh -s - agent
```

Verify node joined:
```bash
ssh root@192.168.1.52 "kubectl get nodes"
```

Expected: `k3s-wrk-4` appears with status `Ready`.

- [ ] **Step 9: Label and taint the node**

From the master:
```bash
ssh root@192.168.1.52 "kubectl label node k3s-wrk-4 role=gpu-inference gpu=tesla-t4 node-type=worker"
ssh root@192.168.1.52 "kubectl taint node k3s-wrk-4 nvidia.com/gpu=present:NoSchedule"
```

Verify:
```bash
ssh root@192.168.1.52 "kubectl describe node k3s-wrk-4 | grep -A5 Labels"
ssh root@192.168.1.52 "kubectl describe node k3s-wrk-4 | grep -A3 Taints"
```

---

### Task 8: GPU passthrough — stop VM 205, assign GPU to VM 207

**Note:** This causes a brief Ollama outage. The Jinja2 fallback in the OSINT platform covers this window.

- [ ] **Step 1: Stop VM 205 (Ollama)**

On cortech-node3:
```bash
ssh root@192.168.1.114 "qm stop 205"
```

Verify stopped:
```bash
ssh root@192.168.1.114 "qm status 205"
```

Expected: `status: stopped`

- [ ] **Step 2: Stop VM 207 to add GPU**

```bash
ssh root@192.168.1.114 "qm stop 207"
```

- [ ] **Step 3: Add GPU passthrough to VM 207**

```bash
ssh root@192.168.1.114 "qm set 207 --hostpci0 0000:3b:00.0,pcie=1,rombar=0,x-vga=0"
```

Verify config:
```bash
ssh root@192.168.1.114 "grep hostpci /etc/pve/qemu-server/207.conf"
```

Expected: `hostpci0: 0000:3b:00.0,pcie=1,rombar=0,x-vga=0`

- [ ] **Step 4: Start VM 207 with GPU**

```bash
ssh root@192.168.1.114 "qm start 207"
```

Wait for boot, then verify GPU:
```bash
ssh k3s@192.168.1.98 "nvidia-smi"
```

Expected: Tesla T4 visible, 16GB VRAM.

- [ ] **Step 5: Deploy NVIDIA device plugin**

From the master:
```bash
ssh root@192.168.1.52 "kubectl apply -f -" < k8s/kube-system/nvidia-device-plugin.yaml
```

Wait for the DaemonSet pod to start:
```bash
ssh root@192.168.1.52 "kubectl -n kube-system get pods -l app=nvidia-device-plugin -o wide"
```

Expected: One pod running on `k3s-wrk-4`.

- [ ] **Step 6: Verify GPU is visible to K8s**

```bash
ssh root@192.168.1.52 "kubectl describe node k3s-wrk-4 | grep nvidia"
```

Expected:
```
  nvidia.com/gpu:     1
  nvidia.com/gpu:     1
```
(Under both Capacity and Allocatable)

---

## Chunk 3: Observability

### Task 9: Create Grafana dashboard ConfigMap

**Files:**
- Create: `k8s/observability/dashboards/applications/vllm-inference.yaml`

**Reference:** Follow template at `k8s/observability/dashboards/applications/_template.yaml` and existing dashboard at `k8s/observability/dashboards/applications/osint-platform.yaml`.

- [ ] **Step 1: Create vLLM Grafana dashboard**

Create `k8s/observability/dashboards/applications/vllm-inference.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-app-vllm-inference
  namespace: observability
  labels:
    grafana_dashboard: "1"
    app.kubernetes.io/name: grafana-dashboard
    app.kubernetes.io/component: application
    release: prometheus
  annotations:
    grafana_folder: "Applications"
data:
  vllm-inference.json: |-
    {
      "annotations": {
        "list": [
          {
            "builtIn": 1,
            "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": true,
            "hide": true,
            "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts",
            "type": "dashboard"
          }
        ]
      },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "id": null,
      "links": [],
      "panels": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {
              "color": {"mode": "thresholds"},
              "mappings": [
                {"options": {"0": {"color": "red", "index": 0, "text": "DOWN"}}, "type": "value"},
                {"options": {"1": {"color": "green", "index": 1, "text": "UP"}}, "type": "value"}
              ],
              "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "green", "value": 1}]}
            },
            "overrides": []
          },
          "gridPos": {"h": 4, "w": 4, "x": 0, "y": 0},
          "id": 1,
          "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "pluginVersion": "11.0.0",
          "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "up{job=\"vllm\"}", "legendFormat": "Status", "refId": "A"}],
          "title": "vLLM Status",
          "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {
              "color": {"mode": "thresholds"},
              "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
              "unit": "ops"
            },
            "overrides": []
          },
          "gridPos": {"h": 4, "w": 4, "x": 4, "y": 0},
          "id": 2,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "pluginVersion": "11.0.0",
          "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "vllm_avg_generation_throughput_toks_per_s", "legendFormat": "tok/s", "refId": "A"}],
          "title": "Generation Throughput",
          "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {
              "color": {"mode": "thresholds"},
              "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 5}, {"color": "red", "value": 10}]},
              "unit": "short"
            },
            "overrides": []
          },
          "gridPos": {"h": 4, "w": 4, "x": 8, "y": 0},
          "id": 3,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "pluginVersion": "11.0.0",
          "targets": [
            {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "vllm_num_requests_running", "legendFormat": "Running", "refId": "A"},
            {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "vllm_num_requests_waiting", "legendFormat": "Waiting", "refId": "B"}
          ],
          "title": "Active Requests",
          "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {
              "color": {"mode": "thresholds"},
              "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.7}, {"color": "red", "value": 0.9}]},
              "unit": "percentunit"
            },
            "overrides": []
          },
          "gridPos": {"h": 4, "w": 4, "x": 12, "y": 0},
          "id": 4,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "pluginVersion": "11.0.0",
          "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "vllm_gpu_cache_usage_perc", "legendFormat": "KV Cache", "refId": "A"}],
          "title": "GPU KV Cache Usage",
          "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {
              "color": {"mode": "palette-classic"},
              "custom": {"axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "insertNulls": false, "lineInterpolation": "smooth", "lineWidth": 2, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
              "mappings": [],
              "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
              "unit": "s"
            },
            "overrides": []
          },
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
          "id": 5,
          "options": {"legend": {"calcs": ["mean", "max", "lastNotNull"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
          "pluginVersion": "11.0.0",
          "targets": [
            {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "histogram_quantile(0.50, sum(rate(vllm_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "P50", "refId": "A"},
            {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "histogram_quantile(0.95, sum(rate(vllm_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "P95", "refId": "B"},
            {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "histogram_quantile(0.99, sum(rate(vllm_request_latency_seconds_bucket[5m])) by (le))", "legendFormat": "P99", "refId": "C"}
          ],
          "title": "Request Latency",
          "type": "timeseries"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {
              "color": {"mode": "palette-classic"},
              "custom": {"axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "insertNulls": false, "lineInterpolation": "smooth", "lineWidth": 2, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
              "mappings": [],
              "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
              "unit": "bytes"
            },
            "overrides": []
          },
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
          "id": 6,
          "options": {"legend": {"calcs": ["mean", "max"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
          "pluginVersion": "11.0.0",
          "targets": [
            {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(container_memory_working_set_bytes{namespace=\"inference\", pod=~\"vllm.*\"}) by (pod)", "legendFormat": "{{pod}}", "refId": "A"}
          ],
          "title": "Memory Usage",
          "type": "timeseries"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "fieldConfig": {
            "defaults": {
              "color": {"mode": "palette-classic"},
              "custom": {"axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "insertNulls": false, "lineInterpolation": "smooth", "lineWidth": 2, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
              "mappings": [],
              "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
              "unit": "short"
            },
            "overrides": []
          },
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12},
          "id": 7,
          "options": {"legend": {"calcs": ["mean", "max"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
          "pluginVersion": "11.0.0",
          "targets": [
            {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"inference\", pod=~\"vllm.*\"}[5m])) by (pod)", "legendFormat": "{{pod}}", "refId": "A"}
          ],
          "title": "CPU Usage",
          "type": "timeseries"
        }
      ],
      "refresh": "30s",
      "schemaVersion": 39,
      "tags": ["application", "vllm", "inference", "gpu"],
      "templating": {
        "list": [
          {
            "current": {"selected": true, "text": "Prometheus", "value": "prometheus"},
            "hide": 0,
            "includeAll": false,
            "label": "Datasource",
            "multi": false,
            "name": "datasource",
            "options": [],
            "query": "prometheus",
            "queryValue": "",
            "refresh": 1,
            "regex": "",
            "skipUrlSync": false,
            "type": "datasource"
          }
        ]
      },
      "time": {"from": "now-1h", "to": "now"},
      "timepicker": {},
      "timezone": "browser",
      "title": "vLLM Inference Dashboard",
      "uid": "app-vllm-inference",
      "version": 1
    }
```

- [ ] **Step 2: Validate YAML**

Run: `yamllint k8s/observability/dashboards/applications/vllm-inference.yaml`
Expected: No errors (long line warnings are OK for JSON inside YAML)

- [ ] **Step 3: Commit**

```bash
git add k8s/observability/dashboards/applications/vllm-inference.yaml
git commit -m "feat(observability): add Grafana dashboard for vLLM inference"
```

---

## Chunk 4: OSINT Cutover and Cleanup

### Task 10: Update OSINT deployments to use vLLM

**Files:**
- Modify: `apps/osint/base/osint-core/deployment.yaml:50-51`
- Modify: `apps/osint/base/osint-worker/deployment.yaml:54-55`
- Modify: `apps/osint/base/osint-beat/deployment.yaml:54-55`

- [ ] **Step 1: Update osint-core deployment**

In `apps/osint/base/osint-core/deployment.yaml`, replace:

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

- [ ] **Step 2: Update osint-worker deployment**

In `apps/osint/base/osint-worker/deployment.yaml`, apply the same replacement:

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

- [ ] **Step 3: Update osint-beat deployment**

In `apps/osint/base/osint-beat/deployment.yaml`, apply the same replacement:

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

- [ ] **Step 4: Validate Kustomize still builds**

Run: `kustomize build apps/osint/overlays/production | grep -A2 "OSINT_VLLM_URL"`
Expected: Shows the new vLLM URL in all three deployments. No references to `OSINT_OLLAMA_URL`.

- [ ] **Step 5: Commit**

```bash
git add apps/osint/base/osint-core/deployment.yaml apps/osint/base/osint-worker/deployment.yaml apps/osint/base/osint-beat/deployment.yaml
git commit -m "feat(osint): switch inference endpoint from Ollama to vLLM"
```

---

### Task 11: Remove Ollama external service

**Files:**
- Delete: `apps/osint/base/external-services/ollama.yaml`
- Modify: `apps/osint/base/kustomization.yaml:9`

- [ ] **Step 1: Remove ollama.yaml reference from kustomization**

In `apps/osint/base/kustomization.yaml`, remove the line:

```yaml
  - external-services/ollama.yaml
```

- [ ] **Step 2: Delete the Ollama external service manifest**

```bash
rm apps/osint/base/external-services/ollama.yaml
```

- [ ] **Step 3: Validate Kustomize still builds**

Run: `kustomize build apps/osint/overlays/production`
Expected: Builds successfully. No Ollama Service or Endpoints in the output.

- [ ] **Step 4: Commit**

```bash
git add apps/osint/base/kustomization.yaml
git rm apps/osint/base/external-services/ollama.yaml
git commit -m "refactor(osint): remove Ollama external service (replaced by vLLM in inference namespace)"
```

**Rollback:** If issues arise after Tasks 10-11, see Spec Section 9, Phase 3 for the rollback procedure: revert env vars, restore `ollama.yaml`, let ArgoCD sync. VM 205 is still available (just stopped).

---

## Chunk 5: Validation and Decommission

### Task 12: Deploy and validate vLLM

**Prerequisites:** VM 207 is running with GPU, K3s node joined, NVIDIA device plugin deployed.

- [ ] **Step 1: Create HuggingFace token secret**

Ensure you have accepted the Meta Llama 3.2 license at https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct.

Create the secret (do NOT commit this in plaintext):
```bash
ssh root@192.168.1.52 "kubectl create secret generic hf-token-secret -n inference --from-literal=token=<your-hf-token>"
```

**For long-term management:** Store the HF token in Infisical (per repo conventions) so the secret survives namespace recreation. ArgoCD with `selfHeal: true` will NOT recreate manually-created secrets.

- [ ] **Step 2: Apply the ArgoCD application**

```bash
ssh root@192.168.1.52 "kubectl apply -f -" < apps/inference/argocd-application.yaml
```

Or push the branch and let ArgoCD auto-sync from Git.

- [ ] **Step 3: Watch vLLM pod startup**

```bash
ssh root@192.168.1.52 "kubectl -n inference get pods -w"
```

Expected: Pod goes from `Pending` → `ContainerCreating` → `Running`. This may take 2-5 minutes on first deploy (model download). Check logs:

```bash
ssh root@192.168.1.52 "kubectl -n inference logs -f deployment/vllm"
```

Expected: Model loading messages, then `INFO: Uvicorn running on http://0.0.0.0:8000`.

- [ ] **Step 4: Verify health endpoint**

```bash
ssh root@192.168.1.52 "kubectl -n inference exec deployment/vllm -- curl -s http://localhost:8000/health"
```

Expected: Returns health status (200 OK).

- [ ] **Step 5: Test inference request**

```bash
ssh root@192.168.1.52 "kubectl run test-vllm --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://vllm.inference.svc.cluster.local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{\"model\": \"meta-llama/Llama-3.2-3B-Instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one sentence.\"}], \"max_tokens\": 50}'"
```

Expected: JSON response with a generated completion.

- [ ] **Step 6: Verify Prometheus metrics**

```bash
ssh root@192.168.1.52 "kubectl -n inference exec deployment/vllm -- curl -s http://localhost:8000/metrics | head -20"
```

Expected: Prometheus-formatted metrics output.

- [ ] **Step 7: Check Grafana dashboard**

Open https://grafana.corbello.io, navigate to Applications folder, verify "vLLM Inference Dashboard" appears with data.

---

### Task 13: Post-cutover validation

**Prerequisites:** Tasks 10-12 complete, ArgoCD has synced OSINT changes.

- [ ] **Step 1: Verify OSINT pods restarted with new env vars**

```bash
ssh root@192.168.1.52 "kubectl -n osint get pods"
ssh root@192.168.1.52 "kubectl -n osint exec deployment/osint-core -- env | grep VLLM"
```

Expected: `OSINT_VLLM_URL=http://vllm.inference.svc.cluster.local:8000` and `OSINT_LLM_MODEL=meta-llama/Llama-3.2-3B-Instruct`

- [ ] **Step 2: Trigger a brief generation and verify**

Use the OSINT API to trigger a brief and confirm it generates using vLLM (not the Jinja2 fallback). Check osint-core logs:

```bash
ssh root@192.168.1.52 "kubectl -n osint logs deployment/osint-core --tail=50"
```

Expected: Logs show successful inference call to vLLM, no fallback triggered.

- [ ] **Step 3: Monitor for 24-48 hours**

Watch:
- Grafana vLLM dashboard: request throughput, latency, GPU cache usage
- OSINT briefs generating correctly
- No Jinja2 fallback triggers (unless node3 is offline)

---

### Task 14: Decommission VM 205 (after validation period)

**Execute this task only after 1-2 weeks of successful vLLM operation.**

- [ ] **Step 1: Stop VM 205**

```bash
ssh root@192.168.1.114 "qm stop 205"
```

- [ ] **Step 2: Disable auto-start**

```bash
ssh root@192.168.1.114 "qm set 205 --onboot 0"
```

- [ ] **Step 3: Update documentation**

Run inventory refresh:
```bash
ssh root@192.168.1.52 "make inventory"
```

Update `CLAUDE.md` architecture tables to reflect:
- VM 205: removed or marked as decommissioned
- VM 207 (`k3s-wrk-4`): added with GPU inference role
- `inference` namespace added to K8s namespaces list
- vLLM added to platform services table

- [ ] **Step 4: Commit documentation updates**

```bash
git add CLAUDE.md
git commit -m "docs: update architecture for vLLM migration (VM 207 replaces VM 205)"
```
