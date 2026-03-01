# Network Infrastructure

**Primary Network:** 192.168.1.0/24  
**Gateway:** 192.168.1.1  
**DNS:** 192.168.1.1 (search domain: corbello.io)  
**Reverse Proxy:** LXC 100 (192.168.1.52)  
**VPN Server:** LXC 102 (192.168.1.52)

## Network Topology

### Core Infrastructure IPs

| Service | IP Address | Purpose | Access |
|---------|------------|---------|--------|
| **Gateway** | 192.168.1.1 | Router/DNS | Internal |
| **Proxmox Host** | 192.168.1.52 | Infrastructure management | Internal |
| **Proxy LXC** | 192.168.1.52 | Nginx reverse proxy | Public |
| **VPN LXC** | 192.168.1.65 | WireGuard dashboard | Public |
| **K3s VIP** | 192.168.1.90 | Traefik ingress (port 30278) | Internal |
| **K3s Master** | 192.168.1.91 | Primary k3s node | Internal |

### Service IP Assignments

#### Kubernetes Cluster
| Node | IP | Role | VM |
|------|----|----- |----|
| k3s-srv-1 | 192.168.1.91 | Master | VMID 200 |
| k3s-srv-2 | 192.168.1.92 | Master | VMID 201 |
| k3s-srv-3 | 192.168.1.93 | Master | VMID 202 |
| k3s-wrk-1 | 192.168.1.94 | Worker | VMID 203 |
| k3s-wrk-2 | 192.168.1.95 | Worker | VMID 204 |
| k3s-wrk-3 | 192.168.1.97 | Worker | VMID 206 |

#### Standalone Services
| Service | IP | Port | Container | Purpose |
|---------|----|----- |-----------|---------|
| Home Assistant | 192.168.1.61 | 8123 | VMID 101 | Home automation |
| WireGuard Dashboard | 192.168.1.65 | 10086 | VMID 102 | VPN management |
| Radarr | 192.168.1.70 | 7878 | External | Movie management |
| Plex | 192.168.1.76 | 32400 | External | Media server |
| Sonarr | 192.168.1.77 | 8989 | External | TV management |
| n8n | 192.168.1.81 | 5678 | VMID 112 | Workflow automation |
| Postal | 192.168.1.82 | 5000 | VMID 113 | Email server |
| PostgreSQL | 192.168.1.86 | 5432 | VMID 114 | Database |
| Redis | 192.168.1.86 | 6379 | VMID 116 | Cache/queue |
| Legal API | 192.168.1.99 | 8000/8001 | VMID 119 | State law API |
| MinIO | 192.168.1.118 | 9000/9001 | VMID 123 | Object storage |
| Uptime Kuma | 192.168.1.121 | 3001 | VMID 120 | Status monitoring |
| Keycloak | 192.168.1.124 | 8080 | VMID 121 | Identity management |

## Reverse Proxy Configuration

**Proxy Server:** Nginx on LXC 100  
**SSL Termination:** Let's Encrypt certificates  
**Configuration:** Pure nginx (no containerization)

### SSL Certificate Status

#### Valid Certificates (24 sites)
| Domain | Expires | Coverage | Notes |
|--------|---------|----------|-------|
| **api.corbello.io** | 44 days | api.corbello.io, argocd.corbello.io, chat.corbello.io | Multi-domain cert |
| **grafana.corbello.io** | 44 days | grafana.corbello.io | K3s ingress |
| **harbor.corbello.io** | 48 days | harbor.corbello.io | Container registry |
| **ha.corbello.io** | 81 days | ha.corbello.io, proxmox.corbello.io, wg.corbello.io | Multi-domain cert |
| **infisical.corbello.io** | 58 days | infisical.corbello.io | Secrets management |
| **keycloak.corbello.io** | 46 days | keycloak.corbello.io | Auth server |
| **legal.api.corbello.io** | 74 days | legal.api.corbello.io, legal.mcp.corbello.io | Legal services |
| **meridian-bridge.co** | 57 days | meridian-bridge.co | Static site |
| **minio-console.corbello.io** | 43 days | minio-console.corbello.io, minio.corbello.io | Object storage |
| **plotlens.ai** | 59 days | plotlens.ai | K3s ingress |
| **rancher.corbello.io** | 44 days | rancher.corbello.io | K3s management |
| **sonarqube.corbello.io** | 47 days | sonarqube.corbello.io | Code analysis |
| **status.corbello.io** | 44 days | status.corbello.io | Status monitoring |

#### Certificates Expiring Soon (⚠️ ≤31 days)
- **n8n.corbello.io** - 31 days
- **postal.corbello.io** - 31 days
- **plex.corbello.io** - 25 days
- **radarr.corbello.io** - 25 days
- **sonarr.corbello.io** - 25 days

#### Invalid Certificates
- **proxmox.corbello.io** - ⚠️ TEST_CERT (self-signed)

### Routing Patterns

#### K3s Ingress Routes (→ 192.168.1.90:30278)
Multiple services route through Traefik ingress controller:
- api.chat.corbello.io, argocd.corbello.io, chat.corbello.io
- grafana.corbello.io, harbor.corbello.io, plotlens.ai
- rancher.corbello.io, sonarqube.corbello.io

**Special Features:**
- Long timeout (3600s) for chat services
- Public access for most services
- LAN restriction for argocd.corbello.io

#### Direct Service Routes
| Domain | Upstream | Purpose |
|--------|----------|---------|
| ha.corbello.io | 192.168.1.61:8123 | Home Assistant |
| keycloak.corbello.io | 192.168.1.124:8080 | Auth server (blocks /management/, /metrics) |
| legal.api.corbello.io | 192.168.1.99:8000 | Legal API service |
| legal.mcp.corbello.io | 192.168.1.99:8001 | Legal MCP service |
| minio.corbello.io | 192.168.1.118:9000 | Object storage S3 API |
| minio-console.corbello.io | 192.168.1.118:9001 | Object storage console |
| n8n.corbello.io | 192.168.1.81:5678 | Workflow automation |
| plex.corbello.io | 192.168.1.76:32400 | Media server |
| postal.corbello.io | 192.168.1.82:5000 | Email server |
| proxmox.corbello.io | 192.168.1.52:8006 | Proxmox web UI |
| radarr.corbello.io | 192.168.1.70:7878 | Movie management |
| sonarr.corbello.io | 192.168.1.77:8989 | TV management |
| status.corbello.io | 192.168.1.121:3001 | Uptime monitoring |
| wg.corbello.io | 192.168.1.65:10086 | WireGuard dashboard |

#### Static Content
- **meridian-bridge.co** - Served from `/var/www/meridian-bridge.co`

## Access Control

### Public Services (Internet Accessible)
Most services are publicly accessible via SSL-terminated reverse proxy.

### Restricted Services
- **argocd.corbello.io** - LAN (192.168.1.0/24) + 24.28.98.7 only
- **minio-console.corbello.io** - LAN (192.168.1.0/24) + 24.28.98.7 only

### Blocked Paths
- **keycloak.corbello.io** - Blocks `/management/`, `/metrics` paths

### Internal-Only Services
- **PostgreSQL** - 192.168.1.86:5432 (no external proxy)
- **Redis** - 192.168.1.86:6379 (no external proxy)
- **K3s NodePorts** - Direct access via 192.168.1.91:30xxx

## VPN Configuration

**VPN Type:** WireGuard  
**Server:** LXC 102 (WireGuard container)  
**Management:** wg.corbello.io (192.168.1.65:10086)

### WireGuard Server Details
- **Interface:** wg0
- **Listen Port:** 51820
- **Public Key:** `6h2b7F45owzSHij8bGb7OIBhDS3aCJHluQq7r/THxkg=`

### VPN Subnet
- **VPN Network:** 10.0.0.0/24
- **Peer 1:** 10.0.0.2/32 (inactive - 136 days since handshake)
- **Peer 2:** 10.0.0.3/32 (never connected)

### VPN Status
⚠️ **Both configured peers are inactive** - may need reconfiguration

## Physical Network

### Proxmox Networking
- **Bridge:** vmbr0 (standard Proxmox bridge)
- **Physical Interface:** eno2 (MAC: f8:bc:12:3d:22:40)
- **Host IP:** 192.168.1.52/24

### Container Network Activity
**Highest Network I/O:**
1. k3s-wrk-3 (VMID 206) - High-density compute node
2. redis (VMID 116) - Application traffic
3. k3s-srv-1 (VMID 200) - Master node traffic

## DNS Configuration

### Search Domain
- **Domain:** corbello.io
- **DNS Server:** 192.168.1.1 (router)

### Service Discovery
Services are accessible via both:
- **Internal IPs:** Direct container/VM access
- **Public Domains:** SSL-terminated via reverse proxy

## Security & Monitoring

### SSL/TLS Status
- **Total Certificates:** 20+ Let's Encrypt certificates
- **Renewal:** Automated via cron on proxy container
- **Monitoring:** Status via status.corbello.io

### Network Security
- **Firewall:** Proxmox host firewall + container-level
- **VPN Access:** WireGuard for remote administration
- **Access Logs:** Nginx access logs on proxy container

### Certificate Monitoring
- **Uptime Kuma:** Monitors SSL certificate validity
- **Alert Thresholds:** 30-day expiration warnings
- **Auto-renewal:** Let's Encrypt ACME client

---

*Last updated: 2026-03-01*