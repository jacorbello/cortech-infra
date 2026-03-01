# K3s Kubernetes Cluster

**Cluster Version:** v1.34.3+k3s1  
**Container Runtime:** containerd://2.1.5-k3s1  
**OS:** Debian GNU/Linux 12 (bookworm)  
**Cluster Age:** 45 days (deployed ~2025-01-15)

## Cluster Topology

### Control Plane Nodes

| Node | VM | Host Node | IP | Resources | CPU Usage | Memory Usage |
|------|-------|-----------|----|-----------| ----------|--------------|
| **k3s-srv-1** | VMID 200 | cortech | 192.168.1.91 | 4 CPU, 8GB RAM | 31% (1270m) | 69% (5548Mi) |
| **k3s-srv-2** | VMID 201 | cortech-node1 | 192.168.1.92 | 2 CPU, 4GB RAM | 62% (1249m) | 55% (2173Mi) |
| **k3s-srv-3** | VMID 202 | cortech-node2 | 192.168.1.93 | 2 CPU, 4GB RAM | 21% (425m) | 77% (3032Mi) |

### Worker Nodes

| Node | VM | Host Node | IP | Resources | CPU Usage | Memory Usage |
|------|-------|-----------|----|-----------| ----------|--------------|
| **k3s-wrk-1** | VMID 203 | cortech-node5 | 192.168.1.94 | 4 CPU, 8GB RAM | 2% (85m) | 60% (4849Mi) |
| **k3s-wrk-2** | VMID 204 | cortech | 192.168.1.95 | 4 CPU, 8GB RAM | 44% (1766m) | 65% (5177Mi) |
| **k3s-wrk-3** | VMID 206 | cortech-node3 | 192.168.1.97 | 48 CPU, 192GB RAM | 0% (118m) | 2% (5297Mi) |

**Cluster Totals:** 62 vCPUs, 296GB RAM across 6 nodes

## Core Infrastructure

### Networking
- **CNI:** Flannel (default k3s)
- **DNS:** kube-dns (CoreDNS)
- **Ingress:** Traefik LoadBalancer (192.168.1.90:30278)
- **Service Mesh:** N/A (native k3s networking)

### Storage
- **CSI Drivers:** Rancher Local Path, NFS CSI
- **Default Storage Class:** local-path (rancher.io/local-path)
- **NFS Storage Class:** nfs-node3 (nfs.csi.k8s.io, server: 192.168.1.114)

## Application Namespaces

### AI/Analytics Platform

#### alastar (AI Assistant Infrastructure)
- **Pods:** 3 running
- **Key Workloads:** Qdrant vector DB, Bull Board task queue, webhook receiver
- **Storage:** alastar-qdrant-pvc (10Gi), webhook-receiver-data (1Gi)
- **External Access:** Bull Board (30380), Webhook (30080), Qdrant (30333/30334)

#### jarvis (AI Chat Platform)
- **Pods:** 9 running
- **Key Workloads:** API, UI, Discord bot, scheduler, workers, Qdrant
- **Storage:** qdrant-pvc (10Gi)
- **Ingress:** chat.corbello.io, api.chat.corbello.io
- **Features:** Long timeout (3600s), public access

#### plotlens (Data Analytics Platform)
- **Pods:** 15 running
- **Key Workloads:** API, frontend, gateway, realtime, workers, Qdrant
- **HPA Scaling:** 4 autoscalers (2-10 replicas)
- **Storage:** Multiple PVCs for different components
- **Domains:** plotlens.corbello.io, api.plotlens.corbello.io, plotlens.ai
- **TLS:** SSL enabled for public domains

### DevOps & Infrastructure

#### argocd (GitOps Platform)
- **Pods:** 7 running
- **Key Workloads:** ArgoCD server, repo server, application controller
- **Version:** v3.2.5
- **Access:** argocd.corbello.io (restricted to LAN + 24.28.98.7)
- **Purpose:** GitOps continuous deployment

#### harbor (Container Registry)
- **Pods:** 7 running
- **Key Workloads:** Harbor registry, core, portal, trivy scanner
- **Version:** v2.14.1
- **Storage:** registry (80Gi), redis (1Gi), trivy (5Gi), jobservice (1Gi)
- **Access:** harbor.corbello.io (public)

#### cattle-system (Rancher Management)
- **Key Workloads:** Rancher server, fleet management
- **ConfigMaps:** 22 | **Secrets:** 13
- **Access:** rancher.corbello.io (public)
- **Purpose:** Kubernetes cluster management

### Security & Secrets

#### infisical (Secrets Management)
- **Pods:** 1 running
- **Version:** v0.96.1
- **Access:** infisical.corbello.io (public), nodeport 30880
- **Purpose:** Application secrets management

#### cert-manager (TLS Management)
- **Purpose:** Automated TLS certificate provisioning
- **Integration:** Let's Encrypt, internal CA

### Business Applications

#### investigations (OSINT Tools)
- **Key Workloads:** ArchiveBox, theHarvester
- **Storage:** archivebox-data (50Gi), theharvester-data (5Gi)
- **External Access:** ArchiveBox (30800), theHarvester (30502)
- **Purpose:** Open-source intelligence gathering

#### trading (Trading Platform)
- **Key Workloads:** Moltbot trading system
- **Storage:** All on NFS (nfs-node3) - moltbot-data (5Gi), journals (1Gi), logs (2Gi)
- **Purpose:** Automated trading operations

#### plotlens-website (Public Website)
- **Purpose:** Static site hosting for plotlens.ai
- **Domains:** plotlens.ai, www.plotlens.ai
- **TLS:** SSL enabled

#### sonarqube (Code Quality)
- **Storage:** data (20Gi), extensions (5Gi), logs (5Gi)
- **Access:** sonarqube.corbello.io
- **Purpose:** Static code analysis

### Observability

#### observability (Monitoring Stack)
- **ConfigMaps:** 44 | **Secrets:** 21 (largest config footprint)
- **Key Workloads:** Prometheus, Grafana, Loki, AlertManager
- **Storage:** prometheus PV (10Gi), loki PV (10Gi)
- **Access:** grafana.corbello.io (public), prometheus nodeport (30090)

### CI/CD

#### actions-runner-system (GitHub Actions)
- **Purpose:** GitHub Actions self-hosted runners
- **Integration:** GitHub repository CI/CD

## External Service Access

### NodePort Services (Direct Access)

| Service | Port | Purpose | External URL |
|---------|------|---------|--------------|
| **qdrant** | 30333/30334 | Vector database API | Direct TCP access |
| **bull-board** | 30380 | Task queue dashboard | http://192.168.1.91:30380 |
| **webhook-receiver** | 30080 | Webhook endpoint | http://192.168.1.91:30080 |
| **infisical-nodeport** | 30880 | Secrets management | http://192.168.1.91:30880 |
| **archivebox** | 30800 | Web archiving | http://192.168.1.91:30800 |
| **theharvester** | 30502 | OSINT gathering | http://192.168.1.91:30502 |
| **gotenberg** | 30300 | PDF generation | http://192.168.1.91:30300 |
| **prometheus-otlp** | 30090 | Metrics collection | http://192.168.1.91:30090 |

### Ingress Services (Via Traefik)

All ingress traffic routes through Traefik at 192.168.1.90:30278

#### Public Access (Internet)
- chat.corbello.io, api.chat.corbello.io (jarvis)
- grafana.corbello.io (monitoring)
- harbor.corbello.io (container registry)
- infisical.corbello.io (secrets)
- plotlens.corbello.io, api.plotlens.corbello.io, plotlens.ai
- rancher.corbello.io (k8s management)
- sonarqube.corbello.io (code quality)

#### Restricted Access (LAN + 24.28.98.7)
- argocd.corbello.io (GitOps management)

## Storage Configuration

### Storage Classes

| Name | Provisioner | Policy | Binding | Expansion | Default |
|------|-------------|--------|---------|-----------|---------|
| **local-path** | rancher.io/local-path | Delete | WaitForFirstConsumer | ❌ | ✅ |
| **nfs-node3** | nfs.csi.k8s.io | Retain | Immediate | ✅ | ❌ |

### Storage Distribution

**Local Path Storage (~320Gi allocated):**
- Harbor registry: 80Gi (largest allocation)
- ArchiveBox data: 50Gi
- SonarQube data: 20Gi
- Alastar/Jarvis Qdrant: 10Gi each
- Prometheus/Loki: 10Gi each
- Multiple smaller allocations (1-5Gi)

**NFS Storage (8Gi allocated):**
- Moltbot trading data: 5Gi
- Moltbot journals: 1Gi
- Moltbot logs: 2Gi
- **NFS Server:** 192.168.1.114 (cortech-node3)

## Scaling & Performance

### Horizontal Pod Autoscalers

| Application | Min | Max | Current | CPU Target | Memory Target |
|-------------|-----|-----|---------|------------|---------------|
| **plotlens-api** | 2 | 10 | 2 | 70% (8% actual) | - |
| **plotlens-gateway** | 2 | 10 | 2 | 70% (1% actual) | 80% (7% actual) |
| **plotlens-realtime** | 2 | 10 | 2 | 70% (3% actual) | 80% (33% actual) |
| **plotlens-worker** | 2 | 10 | 3 | 80% (20% actual) | 85% (59% actual) |

### Resource Utilization Patterns
- **High Memory:** k3s-srv-3 (77%), k3s-srv-1 (69%)
- **High CPU:** k3s-srv-2 (62%), k3s-wrk-2 (44%)
- **Low Utilization:** k3s-wrk-3 (high-capacity node, light load)

## Management & Operations

### GitOps Integration
- **ArgoCD:** Manages deployments via Git repositories
- **Repository Pattern:** Infrastructure as Code

### Monitoring Stack
- **Prometheus:** Metrics collection and storage
- **Grafana:** Visualization and dashboards
- **Loki:** Log aggregation and analysis
- **AlertManager:** Alert routing and management

### Container Registry
- **Harbor:** Internal container registry
- **Features:** Vulnerability scanning (Trivy), image replication
- **Storage:** 80Gi for container images

### Secrets Management
- **Infisical:** Application secrets and configuration
- **Integration:** Kubernetes secrets injection

---

*Last updated: 2026-03-01*