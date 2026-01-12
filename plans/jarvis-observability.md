# Jarvis Observability on a Dedicated Proxmox VM (Logs + Metrics + Traces)

> Centralize Jarvis/LibreChat/AGiXT observability on a standalone VM: Prometheus + Loki + Tempo + Grafana + Alerting.
> This design keeps your monitoring available even when the K3s cluster is degraded.

---

## Outcomes (what you'll gain)
- **Single UI** (Grafana) to answer:
  - "Why did this run reply out-of-order?"
  - "Where did the agent spend time?"
  - "Which tool call failed and what logs match it?"
- **Central retention** (persistent volumes on the VM)
- **Correlation** across systems using:
  - `session_id` (LibreChat thread)
  - `run_id` (one per user message)
  - `task_id` (subtask)
  - `agent` (jarvis / worker / tool)

---

## Architecture (recommended)

### On the Proxmox VM (central store)
- Grafana (UI + dashboards + alerting)
- Prometheus (metrics storage + scraping)
- Alertmanager (notifications)
- Loki (logs)
- Tempo (traces)
- OpenTelemetry Collector (optional, but recommended as the "ingestion router")

### On your K3s cluster + nodes (shippers / exporters)
- Metrics:
  - node-exporter (node CPU/RAM/disk)
  - kube-state-metrics (Kubernetes object metrics)
  - Traefik metrics endpoint scrape
- Logs:
  - Promtail (K8s + node logs) → Loki
- Traces:
  - OTel Collector (in-cluster) → Tempo
- App instrumentation:
  - LibreChat + AGiXT emit JSON logs + OTLP traces

---

## Implementation Status

### Phase 1: VM + Networking ✅
- [x] Create Proxmox LXC container (PCT 122, jarvis-obs)
- [x] Assign static IP: 192.168.1.122
- [x] Ports available: 3000 (Grafana), 9090 (Prometheus), 3100 (Loki), 3200 (Tempo), 4317/4318 (OTLP)

### Phase 2: OS Hardening ✅
- [x] Update OS packages (Ubuntu 22.04)
- [x] Running as root in container (standard for LXC)

### Phase 3: Docker + Compose ✅
- [x] Install Docker Engine + Compose plugin
- [x] Create directory structure `/opt/obs/`

### Phase 4: Deploy Observability Stack ✅
- [x] Create docker-compose.yml (Grafana, Prometheus, Alertmanager, Loki, Tempo)
- [x] Create prometheus.yml config
- [x] Create loki.yml config
- [x] Create tempo.yml config
- [x] Create alertmanager.yml config
- [x] Start the stack and verify - all containers running

### Phase 5: Cluster Shippers/Exporters (Partial)
- [x] Install node-exporter on cortech (192.168.1.52:9100)
- [ ] Install node-exporter on other cluster nodes
- [ ] Deploy kube-state-metrics in cluster
- [ ] Deploy promtail in cluster
- [ ] Deploy OTel Collector in cluster

### Phase 6: Jarvis Instrumentation
- [ ] Standardize session_id/run_id/task_id/agent in logs (JSON)
- [ ] Add OTLP tracing in LibreChat → AGiXT call path
- [ ] Add trace IDs into logs (log ↔ trace correlation)

### Phase 7: Dashboards + Alerts
- [ ] Configure Grafana datasources (Prometheus, Loki, Tempo)
- [ ] Import/create dashboards: Nodes, K8s, Traefik, Jarvis Runs
- [ ] Configure alerts: disk > 80%, scrape down, ingest errors, 5xx spikes

### Phase 8: Secure Access
- [ ] Expose Grafana via Traefik reverse proxy
- [ ] Apply auth middleware
- [ ] Keep Loki/Tempo internal-only

---

## 1) Proxmox VM Build

### Sizing (starting point)
- vCPU: 4
- RAM: 8–16 GB (logs can eat memory; 16 GB is comfy)
- Disk: 200–500 GB (depends on retention)
- NIC: bridged to LAN (static IP)

### VM Details
- **VMID**: 122
- **Name**: jarvis-obs
- **IP**: 192.168.1.122
- **DNS**: obs.corbello.io

---

## 2) OS Hardening Baseline

```bash
# Update OS
sudo apt update && sudo apt -y upgrade

# Create admin user (if needed)
sudo adduser obsadmin
sudo usermod -aG sudo obsadmin

# Enable UFW
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 3000 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 3100 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 3200 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 4317 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 9090 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 9093 proto tcp
sudo ufw enable
```

---

## 3) Install Docker + Compose

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
docker version
docker compose version
```

---

## 4) Deploy the Observability Stack

### Directory Structure
```bash
sudo mkdir -p /opt/obs/{grafana,prometheus,alertmanager,loki,tempo,otel,data}
sudo mkdir -p /opt/obs/data/{grafana,prometheus,loki,tempo}
sudo chown -R $USER:$USER /opt/obs
```

### 4.1 docker-compose.yml

```yaml
services:
  grafana:
    image: grafana/grafana:latest
    ports: ["3000:3000"]
    volumes:
      - /opt/obs/data/grafana:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
    depends_on: [prometheus, loki, tempo]
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    ports: ["9090:9090"]
    volumes:
      - /opt/obs/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /opt/obs/data/prometheus:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=15d"
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:latest
    ports: ["9093:9093"]
    volumes:
      - /opt/obs/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    restart: unless-stopped

  loki:
    image: grafana/loki:latest
    ports: ["3100:3100"]
    volumes:
      - /opt/obs/loki/loki.yml:/etc/loki/config.yml:ro
      - /opt/obs/data/loki:/loki
    command: ["-config.file=/etc/loki/config.yml"]
    restart: unless-stopped

  tempo:
    image: grafana/tempo:latest
    ports:
      - "3200:3200"    # tempo query
      - "4317:4317"    # OTLP gRPC ingest
      - "4318:4318"    # OTLP HTTP ingest
    volumes:
      - /opt/obs/tempo/tempo.yml:/etc/tempo.yml:ro
      - /opt/obs/data/tempo:/var/tempo
    command: ["-config.file=/etc/tempo.yml"]
    restart: unless-stopped
```

### 4.2 prometheus.yml

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node-exporter"
    static_configs:
      - targets:
          - "192.168.1.52:9100"   # cortech
          - "192.168.1.72:9100"   # cortech-node1
          - "192.168.1.73:9100"   # cortech-node2
          - "192.168.1.74:9100"   # cortech-node3
          - "192.168.1.76:9100"   # cortech-node5
```

### 4.3 loki.yml

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 336h # 14d
```

### 4.4 tempo.yml

```yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
        http:

storage:
  trace:
    backend: local
    local:
      path: /var/tempo
```

### 4.5 alertmanager.yml

```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'

receivers:
  - name: 'default'
    # Configure webhook to Home Assistant or other notification system
```

---

## 5) Ship Metrics from Nodes (node-exporter)

### Option A: systemd on each node (simple)

```bash
sudo apt update
sudo apt -y install prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
```

Verify from VM:
```bash
curl http://192.168.1.52:9100/metrics | head
```

---

## 6) Ship Logs to Loki (promtail)

Promtail runs as a DaemonSet in K3s cluster, collecting:
- `/var/log/pods/...` container logs
- Node journal logs (optional)

Key labels to add:
- cluster, namespace, pod, container
- For Jarvis apps: service, agent, session_id, run_id, task_id

---

## 7) Ship Traces to Tempo (OTel Collector)

Run OTel Collector in-cluster that exports OTLP to the VM:
- Exporter endpoint: `http://192.168.1.122:4317` (gRPC) or `:4318` (HTTP)

---

## 8) Jarvis Instrumentation

### 8.1 Standard JSON logging fields

Every component logs JSON with:
- timestamp, level, service, agent
- session_id, run_id, task_id
- trace_id, span_id (when available)
- duration_ms, status, error

### 8.2 Tracing (OTLP)

- LibreChat → AGiXT HTTP calls: create span `librechat.send_to_agixt`
- Jarvis orchestrator: span per tool call
- Propagate trace context across internal calls

**Important**: Do NOT label Prometheus metrics with run_id (cardinality bomb). Put run_id in logs/traces only.

---

## 9) Grafana Setup

### Datasources
- Prometheus: `http://prometheus:9090`
- Loki: `http://loki:3100`
- Tempo: `http://tempo:3200`

### Dashboards
- Node exporter full (per node health)
- Loki "Logs Explorer"
- Tempo "Traces Explorer"
- Custom: "Jarvis Runs" - errors by service/agent, latency by span, recent runs table

---

## 10) Retention + Storage

| System | Retention | Notes |
|--------|-----------|-------|
| Prometheus | 15d | Metrics |
| Loki | 14d | Logs |
| Tempo | 7d | Traces (disk intensive) |

Monitor disk usage and alert at 70/80/90%.

---

## 11) Validation Tests

- [x] **Metrics test**: Prometheus targets show UP for cortech node-exporter (192.168.1.52:9100)
- [x] **Logs test**: Test log sent to Loki and retrieved successfully
- [ ] **Traces test**: Trigger LibreChat → Jarvis call, confirm trace in Tempo
- [ ] **Correlation test**: Confirm logs include trace_id and can jump logs ↔ trace

---

## Access Information

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://192.168.1.122:3000 | admin / changeme123 |
| Prometheus | http://192.168.1.122:9090 | N/A |
| Loki | http://192.168.1.122:3100 | N/A |
| Tempo | http://192.168.1.122:3200 | N/A |

**Datasources configured in Grafana:**
- Prometheus (default)
- Loki
- Tempo

**Dashboard imported:**
- Node Exporter Full (ID: 1860)

---

*Last updated: 2026-01-11*
