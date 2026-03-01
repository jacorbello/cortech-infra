# Homelab Infrastructure Overview

This directory contains comprehensive documentation of the corbello.io homelab infrastructure.

## Documentation Structure

| Document | Purpose |
|----------|---------|
| **[proxmox.md](proxmox.md)** | Proxmox cluster nodes, VMs/LXCs, storage backends |
| **[k3s-cluster.md](k3s-cluster.md)** | Kubernetes cluster overview, namespaces, services |
| **[network.md](network.md)** | Network topology, reverse proxy, SSL certificates |
| **[services.md](services.md)** | Standalone services running outside k3s |

## Cluster Summary

**Proxmox Cluster:** cortech (5 nodes)  
**K3s Cluster:** 6 VMs (3 masters, 3 workers)  
**Total Infrastructure:** 19 VMs/LXCs (16 running, 3 stopped)

## Quick Reference - Key Services

| Service | External URL | Internal Access | Purpose |
|---------|-------------|-----------------|---------|
| **n8n** | https://n8n.corbello.io | 192.168.1.81:5678 | Workflow automation |
| **Grafana** | https://grafana.corbello.io | K3s ingress | Monitoring dashboards |
| **Uptime Kuma** | https://status.corbello.io | 192.168.1.121:3001 | Status monitoring |
| **Harbor** | https://harbor.corbello.io | K3s ingress | Container registry |
| **ArgoCD** | https://argocd.corbello.io | K3s ingress | GitOps management |
| **Rancher** | https://rancher.corbello.io | K3s ingress | K3s management |
| **MinIO** | https://minio.corbello.io | 192.168.1.118:9000 | Object storage |
| **Postal** | https://postal.corbello.io | 192.168.1.82:5000 | Email server |
| **Home Assistant** | https://ha.corbello.io | 192.168.1.61:8123 | Home automation |
| **Proxmox** | https://proxmox.corbello.io | 192.168.1.52:8006 | Infrastructure management |
| **Plex** | https://plex.corbello.io | 192.168.1.76:32400 | Media server |
| **Infisical** | https://infisical.corbello.io | 192.168.1.91:30880 | Secrets management |
| **PostgreSQL** | N/A | 192.168.1.86:5432 | Database server |
| **Redis** | N/A | 192.168.1.86:6379 | Cache/queue |
| **Qdrant** | N/A | 192.168.1.91:30333 | Vector database |

## Core Infrastructure Components

### Proxmox Cluster (Physical)
- **Master:** cortech (12 cores, 189GB RAM)
- **Workers:** cortech-node1, node2, node3, node5
- **Total:** 124 cores, 849GB RAM across 5 nodes

### K3s Kubernetes Cluster (Virtual)
- **Version:** v1.34.3+k3s1
- **Masters:** 192.168.1.91/92/93 (k3s-srv-1/2/3)
- **Workers:** 192.168.1.94/95/97 (k3s-wrk-1/2/3)
- **Ingress:** Traefik LoadBalancer on 192.168.1.90:30278

### Storage Backends
- **Proxmox:** local-lvm (primary), storage-pool (ZFS), media-storage (CIFS)
- **K3s:** local-path (default), nfs-node3 (NFS CSI from 192.168.1.114)

### Network Infrastructure
- **Primary Network:** 192.168.1.0/24
- **Proxy:** LXC 100 (nginx reverse proxy)
- **VPN:** LXC 102 (WireGuard)
- **DNS:** 192.168.1.1 with corbello.io search domain

## Application Domains

### AI/Analytics Platform
- **Jarvis:** AI chat platform (jarvis namespace)
- **PlotLens:** Data analytics platform (plotlens namespace)
- **Alastar:** AI assistant infrastructure (alastar namespace)

### DevOps & Infrastructure
- **Harbor:** Container registry
- **ArgoCD:** GitOps deployments
- **Rancher:** Kubernetes management
- **SonarQube:** Code quality analysis

### Media & Entertainment
- **Plex:** Media streaming
- **Radarr/Sonarr:** Media management
- **Minecraft:** Bedrock server

### Business Services
- **Postal:** Email server
- **n8n:** Workflow automation
- **Legal API:** State law collector

### Monitoring & Security
- **Grafana/Prometheus:** Metrics and monitoring
- **Uptime Kuma:** Service status monitoring
- **Infisical:** Secrets management
- **Keycloak:** Identity provider

## Network Access Patterns

### Public Services (Internet accessible)
All services are publicly accessible via SSL-terminated reverse proxy except where noted.

### Restricted Services
- **ArgoCD:** LAN + 24.28.98.7 only
- **MinIO Console:** LAN + 24.28.98.7 only

### Internal Services
- **PostgreSQL:** 192.168.1.86:5432 (database backend)
- **Redis:** 192.168.1.86:6379 (cache/queue backend)
- **Qdrant:** 192.168.1.91:30333 (vector database)

---

*Last updated: 2026-03-01*