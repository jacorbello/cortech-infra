# Proxmox Infrastructure

**Cluster Name:** cortech  
**Management Interface:** https://proxmox.corbello.io (192.168.1.52:8006)  
**SSH Access:** `ssh root@192.168.1.52`  
**Version:** Proxmox VE 9.1.4

## Cluster Overview

**Total Infrastructure:** 19 VMs/LXCs (16 running, 3 stopped)  
**Physical Nodes:** 5 active nodes  
**Uptime:** 171 days (most nodes), 34 days (cortech-node3), 169 days (cortech-node5)

## Node Specifications

| Node | Role | Status | CPU Cores | Memory (GB) | Storage (GB) | Load % | Uptime |
|------|------|--------|-----------|-------------|--------------|---------|---------|
| **cortech** | Master | Online | 12 | 189 | 95 | 70.6% | 171 days |
| **cortech-node1** | Worker | Online | 4 | 30 | 65 | 11.4% | 171 days |
| **cortech-node2** | Worker | Online | 4 | 30 | 68 | 16.6% | 171 days |
| **cortech-node3** | Worker | Online | 96 | 567 | 64 | 0.2% | 34 days |
| **cortech-node5** | Worker | Online | 8 | 31 | 94 | 2.0% | 169 days |

**Cluster Totals:**
- **CPU:** 124 physical cores, 114 allocated vCPUs
- **Memory:** 849 GB physical, 408 GB allocated
- **Storage:** 386 GB across nodes

## Running VMs and LXCs

### Kubernetes Cluster (6 VMs)

| VMID | Name | Node | IP | Role | Resources | Purpose |
|------|------|------|----|----- |-----------|---------|
| **200** | k3s-srv-1 | cortech | 192.168.1.91 | Master | 4 CPU, 8GB RAM, 100GB | Control plane |
| **201** | k3s-srv-2 | cortech-node1 | 192.168.1.92 | Master | 2 CPU, 4GB RAM, 40GB | Control plane |
| **202** | k3s-srv-3 | cortech-node2 | 192.168.1.93 | Master | 2 CPU, 4GB RAM, 40GB | Control plane |
| **203** | k3s-wrk-1 | cortech-node5 | 192.168.1.94 | Worker | 4 CPU, 8GB RAM, 100GB | Workloads |
| **204** | k3s-wrk-2 | cortech | 192.168.1.95 | Worker | 4 CPU, 8GB RAM, 60GB | Workloads |
| **206** | k3s-wrk-3 | cortech-node3 | 192.168.1.97 | Worker | 48 CPU, 192GB RAM, 60GB | High-density compute |

**K3s Resources:** 62 cores, 296 GB RAM total

### Core Infrastructure Services (10 LXCs)

| VMID | Name | Node | Type | Resources | Purpose |
|------|------|------|------|-----------|---------|
| **100** | proxy | cortech | LXC | 1 CPU, 512MB, 8GB | Nginx reverse proxy (critical) |
| **102** | wireguard | cortech | LXC | 1 CPU, 512MB, 4GB | WireGuard VPN server |
| **112** | n8n | cortech-node5 | LXC | 4 CPU, 8GB, 32GB | Workflow automation |
| **113** | postal | cortech-node1 | LXC | 2 CPU, 4GB, 32GB | Email server |
| **114** | postgres | cortech | LXC | 4 CPU, 8GB, 256GB | PostgreSQL database |
| **116** | redis | cortech | LXC | 4 CPU, 32GB, 96GB | Redis cache/queue (critical) |
| **119** | legal-api | cortech | LXC | 4 CPU, 8GB, 32GB | Legal API service |
| **120** | uptime-kuma | cortech | LXC | 1 CPU, 1GB, 8GB | Status monitoring |
| **121** | keycloak | cortech | LXC | 2 CPU, 2GB, 8GB | Identity management |
| **123** | minio-01 | cortech | LXC | 4 CPU, 8GB, 502GB | MinIO object storage |

### Application Services (3 VMs)

| VMID | Name | Node | Type | Resources | Purpose |
|------|------|------|------|-----------|---------|
| **101** | homeassistant | cortech | QEMU | 2 CPU, 4GB, 32GB | Home Assistant |
| **105** | minecraft-bedrock | cortech | LXC | 6 CPU, 8GB, 32GB | Minecraft server |
| **205** | ollama | cortech-node3 | QEMU | 8 CPU, 64GB, 100GB | Ollama LLM (GPU) |

### Stopped/Template Services (3)

| VMID | Name | Node | Status | Purpose |
|------|------|------|--------|---------|
| **111** | wordpress-ff | cortech-node2 | Stopped | Family Friendly WordPress |
| **117** | gha-runner-personal | cortech | Stopped | GitHub Actions runner |
| **9000** | k3s-template | cortech | Stopped | Template VM for k3s |

## Storage Backends

| Storage ID | Type | Content Types | Nodes | Details |
|------------|------|---------------|-------|---------|
| **local-lvm** | LVM-Thin | VM disks, containers | All | Primary storage, thin provisioning |
| **local** | Directory | ISO, templates, backups | All | `/var/lib/vz` |
| **storage-pool** | ZFS Pool | VM disks, containers | All | ZFS storage pool |
| **media-storage** | CIFS | Backups, containers | All | NFS share from 192.168.1.52 |

## Resource Allocation Analysis

### High-Resource Services
- **k3s-wrk-3 (206):** 48 cores, 192GB RAM - high-density compute
- **ollama (205):** 8 cores, 64GB RAM - GPU passthrough for AI inference
- **redis (116):** 32GB RAM - large memory cache
- **minio-01 (123):** 502GB storage - object storage backend

### Critical Infrastructure (Tagged)
- **proxy (100):** Nginx reverse proxy - all external access
- **redis (116):** Cache and queue backend - application dependency

### Node Specialization
- **cortech:** Mixed workloads, highest utilization (70.6%)
- **cortech-node3:** High-density compute (k3s-wrk-3, ollama)
- **cortech-node1:** K3s master + email (postal)
- **cortech-node2:** K3s master, lowest utilization
- **cortech-node5:** K3s worker + workflow automation (n8n)

## Network Configuration

**Bridge:** vmbr0 (standard Proxmox bridge)  
**Physical Interface:** eno2 (f8:bc:12:3d:22:40)  
**Network Range:** 192.168.1.0/24

### Network Activity Leaders
1. **k3s-wrk-3 (206):** Highest network I/O
2. **redis (116):** High I/O from application traffic
3. **k3s-srv-1 (200):** Master node traffic

## Special Configurations

### GPU Passthrough
- **VMID 205 (ollama):** GPU passthrough for AI inference workloads

### Container Features
- **Nesting Enabled:** Where required for containerized workloads
- **Unprivileged Containers:** Security best practice where possible

### Template Management
- **VMID 9000:** k3s-template for rapid VM deployment

## Security & Access

### SSH Access
- **Primary:** `ssh root@192.168.1.52` (cluster management)
- **Individual containers:** SSH available on port 22

### Firewall & Security
- **Web UI:** Proxmox firewall rules configured
- **Container Security:** Unprivileged containers where possible
- **Critical Service Tagging:** Priority monitoring enabled

## Backup Strategy

### Storage Integration
- **CIFS Share:** media-storage backend for backups
- **Local Storage:** `/var/lib/vz` for templates and immediate backups

### Backup Schedule
- **Templates:** Stored in local and CIFS storage
- **Container Backups:** Configured via CIFS media-storage

---

*Last updated: 2026-03-01*