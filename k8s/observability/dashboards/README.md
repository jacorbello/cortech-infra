# Grafana Dashboards

This directory contains Grafana dashboard definitions deployed as Kubernetes ConfigMaps. The Grafana sidecar automatically discovers and provisions these dashboards.

## Directory Structure

```
dashboards/
├── infrastructure/     # Proxmox, K3s, and system-level dashboards
│   ├── proxmox-cluster-overview.yaml
│   ├── proxmox-node-resources.yaml
│   ├── proxmox-guests.yaml
│   ├── k3s-cluster-health.yaml
│   └── storage-networking.yaml
└── applications/       # Application-specific dashboards
    ├── _template.yaml
    └── README.md
```

## How It Works

1. Dashboard JSON is embedded in ConfigMap data
2. ConfigMaps are labeled with `grafana_dashboard: "1"` for sidecar discovery
3. The `grafana_folder` annotation determines which Grafana folder the dashboard appears in
4. Grafana's sidecar watches for ConfigMap changes and automatically syncs

## Folder Organization

| Folder | Annotation | Contents |
|--------|------------|----------|
| Cortech | `grafana_folder: "Cortech"` | Infrastructure dashboards (Proxmox, K3s) |
| Applications | `grafana_folder: "Applications"` | Application-specific dashboards |

## Required Labels and Annotations

All dashboard ConfigMaps must have:

```yaml
metadata:
  labels:
    grafana_dashboard: "1"           # Required for sidecar discovery
    release: prometheus              # Required for Helm selector
  annotations:
    grafana_folder: "Cortech"        # Folder name in Grafana
```

## Helm Configuration

The following Helm values enable folder support in kube-prometheus-stack:

```yaml
grafana:
  sidecar:
    dashboards:
      folderAnnotation: grafana_folder
      provider:
        foldersFromFilesStructure: true
    datasources:
      skipReload: false
```

## Deploying Dashboards

```bash
# Apply all infrastructure dashboards
kubectl apply -f k8s/observability/dashboards/infrastructure/

# Apply a specific dashboard
kubectl apply -f k8s/observability/dashboards/infrastructure/proxmox-cluster-overview.yaml

# Verify dashboards are loaded
kubectl get configmaps -n observability -l grafana_dashboard=1
```

## Troubleshooting

### Dashboards not appearing
1. Check sidecar logs:
   ```bash
   kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard
   ```
2. Verify ConfigMap labels:
   ```bash
   kubectl get configmap <name> -n observability --show-labels
   ```

### Datasources missing
Trigger a manual reload:
```bash
curl -X POST -u admin:<password> https://grafana.corbello.io/api/admin/provisioning/datasources/reload
```

### Dashboard in wrong folder
Update the `grafana_folder` annotation and reapply the ConfigMap.
