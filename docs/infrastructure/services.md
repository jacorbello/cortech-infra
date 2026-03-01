# Standalone Services

This document covers services running on dedicated LXC containers and VMs outside the k3s cluster.

## Database Services

### PostgreSQL (VMID 114, LXC)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | LXC Container |
| **Resources** | 4 CPU, 8GB RAM, 256GB storage |
| **Network Access** | 192.168.1.86:5432 (internal only) |
| **Version** | PostgreSQL 15.16 (Debian 15.16-0+deb12u1) |
| **Management** | Webmin on port 12321 |

**Databases:**
- postgres, root (system)
- template0, template1 (system templates)
- tweetarchiver (legacy)
- legal_api, jarvis, keycloak, sonarqube (application DBs)
- harbor, harbor_notary_server, harbor_notary_signer (registry)
- plotlens, infisical (platform DBs)

**Additional Services:**
- Lighttpd web server (port 80/443)
- SSH access (port 22)
- Webmin management interface (port 12321)

### Redis (VMID 116, LXC)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | LXC Container |
| **Resources** | 4 CPU, 32GB RAM, 96GB storage |
| **Network Access** | 192.168.1.86:6379 (internal only) |
| **Authentication** | Required |
| **Role** | Tagged as "critical" infrastructure |

**Additional Services:**
- Nginx reverse proxy (port 80/443)
- PM2 process manager
- Fail2Ban protection
- Postfix mail service (port 25)
- SSH access (port 22)
- Webmin management (port 12321)

## Application Services

### Legal API (VMID 119, LXC)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | LXC Container |
| **Resources** | 4 CPU, 8GB RAM, 32GB storage |
| **External Access** | legal.api.corbello.io, legal.mcp.corbello.io |
| **Internal Ports** | 8000 (FastAPI), 8001 (MCP Server), 6379 (Redis) |

**Services:**
- **legal-api.service** - FastAPI application (port 8000)
- **legal-celery.service** - Celery worker for background jobs
- **legal-mcp.service** - MCP Server for HTTP interface (port 8001)
- **Local Redis** - Task queue for Celery (port 6379)
- **Postfix** - Email functionality (port 25)
- **SSH** - Administrative access (port 22)

**Purpose:** State law data collection and API services

### n8n Workflow Automation (VMID 112, LXC) ⚠️

| Property | Details |
|----------|---------|
| **Host Node** | cortech-node5 |
| **Type** | LXC Container |
| **Resources** | 4 CPU, 8GB RAM, 32GB storage |
| **External Access** | https://n8n.corbello.io |
| **Status** | ⚠️ Not accessible from proxy LXC during inventory |

**Note:** This service exists per Proxmox data but was not accessible from the proxy LXC (100) used for network scanning. The service is running on cortech-node5, which may have different network routing or firewall rules.

### Postal Email Server (VMID 113, LXC) ⚠️

| Property | Details |
|----------|---------|
| **Host Node** | cortech-node1 |
| **Type** | LXC Container |
| **Resources** | 2 CPU, 4GB RAM, 32GB storage |
| **External Access** | https://postal.corbello.io |
| **Status** | ⚠️ Not accessible from proxy LXC during inventory |

**Note:** This service exists per Proxmox data but was not accessible from the proxy LXC (100) used for network scanning. The service is running on cortech-node1, which may have different network routing or firewall rules.

## Monitoring & Management

### Uptime Kuma (VMID 120, LXC)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | LXC Container |
| **Resources** | 1 CPU, 1GB RAM, 8GB storage |
| **External Access** | https://status.corbello.io |
| **Internal Port** | 3001 |
| **Deployment** | Docker container |

**Container Details:**
- **Image:** louislam/uptime-kuma:2
- **Container ID:** 145691efad61
- **Status:** Healthy (health check passing)
- **Uptime:** 16+ hours (container), 6 weeks (created)

**Purpose:** Service uptime monitoring and status dashboard

### Keycloak Identity Provider (VMID 121, LXC)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | LXC Container |
| **Resources** | 2 CPU, 2GB RAM, 8GB storage |
| **External Access** | https://keycloak.corbello.io |
| **Internal Port** | 8080 |
| **Deployment** | systemd service |

**Services:**
- **keycloak.service** - Identity and access management
- **Postfix** - Email notifications (port 25)
- **SSH** - Administrative access (port 22)

**Purpose:** Identity and access management across platform services

## Storage Services

### MinIO Object Storage (VMID 123, LXC)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | LXC Container |
| **Resources** | 4 CPU, 8GB RAM, 502GB storage |
| **External Access** | https://minio.corbello.io, https://minio-console.corbello.io |
| **Internal Ports** | 9000 (API), 9001 (Console) |
| **Deployment** | Docker container |

**Container Details:**
- **Image:** quay.io/minio/minio:latest
- **Container ID:** 506671b70c20
- **Status:** Healthy (health check passing)
- **Uptime:** 6 weeks
- **Purpose:** S3-compatible object storage backend

**Access Control:**
- **API (9000):** Public access
- **Console (9001):** Restricted to LAN + 24.28.98.7

## Home Automation

### Home Assistant (VMID 101, QEMU VM)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | QEMU VM |
| **Resources** | 2 CPU, 4GB RAM, 32GB storage |
| **Network** | 192.168.1.61 |
| **External Access** | https://ha.corbello.io |
| **Port** | 8123 |

**System Details:**
- **OS:** Home Assistant OS (HassIO architecture)
- **Networks:** hassio (172.30.32.1), docker0 (172.30.232.1)
- **Architecture:** Containerized services with multiple veth interfaces
- **Guest Agent:** Active (responds to Proxmox queries)

**Purpose:** Smart home automation and IoT device management

## Gaming Services

### Minecraft Bedrock (VMID 105, LXC)

| Property | Details |
|----------|---------|
| **Host Node** | cortech |
| **Type** | LXC Container |
| **Resources** | 6 CPU, 8GB RAM, 32GB storage |
| **Network Access** | Internal (game protocol ports) |
| **Purpose** | Minecraft Bedrock Edition server |

## AI/ML Services

### Ollama (VMID 205, QEMU VM) ⚠️

| Property | Details |
|----------|---------|
| **Host Node** | cortech-node3 |
| **Type** | QEMU VM |
| **Resources** | 8 CPU, 64GB RAM, 100GB storage |
| **Network** | 192.168.1.96 |
| **Features** | GPU passthrough for AI inference |
| **Status** | ⚠️ Not accessible from proxy LXC during inventory |

**Note:** This service exists per Proxmox data but was not accessible from the proxy LXC (100) used for network scanning. The service is running on cortech-node3 with GPU acceleration, which may have specialized network configuration.

## Stopped/Maintenance Services

### WordPress Family Friendly (VMID 111, LXC)
- **Host Node:** cortech-node2
- **Status:** Stopped
- **Purpose:** Family Friendly WordPress site (maintenance mode)

### GitHub Actions Runner (VMID 117, LXC)
- **Host Node:** cortech
- **Status:** Stopped  
- **Purpose:** Personal GitHub Actions runner (inactive)

### k3s Template (VMID 9000, QEMU VM)
- **Host Node:** cortech
- **Status:** Stopped
- **Purpose:** Template VM for k3s node deployment

## Infrastructure Components

### Proxy (VMID 100, LXC)
- **Host Node:** cortech
- **Type:** LXC Container
- **Resources:** 1 CPU, 512MB RAM, 8GB storage
- **Role:** Tagged as "critical" infrastructure
- **Purpose:** Nginx reverse proxy for all external services
- **Configuration:** Pure nginx (no containerization)

### WireGuard VPN (VMID 102, LXC)
- **Host Node:** cortech
- **Type:** LXC Container
- **Resources:** 1 CPU, 512MB RAM, 4GB storage
- **External Access:** https://wg.corbello.io
- **Purpose:** WireGuard VPN server and management dashboard

## Deployment Patterns

### Container Technologies
- **Docker:** Uptime Kuma, MinIO
- **systemd Services:** PostgreSQL, Redis, legal-api, Keycloak
- **HassIO/Container OS:** Home Assistant
- **Pure Services:** Nginx (proxy), WireGuard

### Resource Allocation
- **High Memory:** Redis (32GB) - cache/queue workload
- **High Storage:** MinIO (502GB) - object storage backend
- **High CPU:** Minecraft (6 cores), legal-api (4 cores)
- **GPU Access:** Ollama (GPU passthrough for AI inference)

### Security Features
- **Critical Tagging:** Proxy (100), Redis (116) marked as critical infrastructure
- **Access Control:** Webmin, SSH access configured per service
- **Authentication:** Redis requires authentication, PostgreSQL has role-based access

## Missing Services Investigation

**Issue:** Three services (n8n, postal, ollama) were not accessible during inventory scanning from the proxy LXC (100). However, these services **do exist** according to Proxmox data:

- **n8n (VMID 112)** - Running on cortech-node5
- **postal (VMID 113)** - Running on cortech-node1  
- **ollama (VMID 205)** - Running on cortech-node3

**Likely Causes:**
1. **Network Routing:** Services on different Proxmox nodes may have different routing
2. **Firewall Rules:** Node-specific firewall configurations
3. **Service Binding:** Services may be binding to localhost/specific IPs only
4. **Inventory Vantage Point:** Scanning from proxy LXC may not have access to all node networks

**Next Steps:** Direct investigation from each Proxmox node or service container needed to confirm service configurations and accessibility.

---

*Last updated: 2026-03-01*