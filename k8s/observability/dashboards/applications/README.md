# Application Dashboards

This directory contains Grafana dashboard definitions for application-specific monitoring.

## Adding a New Application Dashboard

1. Copy the template:
   ```bash
   cp _template.yaml my-app.yaml
   ```

2. Replace placeholders in `my-app.yaml`:
   - `<APP_NAME>` - Your application name (lowercase, hyphenated)
   - `<APP_NAMESPACE>` - Kubernetes namespace where your app runs

3. Customize the dashboard:
   - Add application-specific metrics panels
   - Configure alerts if needed
   - Adjust time ranges and refresh intervals

4. Apply the dashboard:
   ```bash
   kubectl apply -f my-app.yaml
   ```

5. The dashboard will automatically appear in Grafana under the "Applications" folder.

## Dashboard Requirements

All dashboard ConfigMaps must have:
- Label: `grafana_dashboard: "1"` - Required for Grafana sidecar discovery
- Label: `release: prometheus` - Required for Helm selector matching
- Annotation: `grafana_folder: "Applications"` - For folder organization

## Example Metrics to Include

Common metrics to add to application dashboards:

### HTTP Services
```promql
# Request rate
sum(rate(http_requests_total{namespace="$namespace"}[5m])) by (status_code)

# Request latency p99
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="$namespace"}[5m])) by (le))

# Error rate
sum(rate(http_requests_total{namespace="$namespace", status_code=~"5.."}[5m])) / sum(rate(http_requests_total{namespace="$namespace"}[5m]))
```

### Database Connections
```promql
# Active connections
pg_stat_activity_count{datname="$database"}

# Query duration
pg_stat_statements_mean_time_seconds{datname="$database"}
```

### Queue/Message Processing
```promql
# Queue depth
rabbitmq_queue_messages{queue="$queue"}

# Processing rate
sum(rate(messages_processed_total[5m]))
```

## File Naming Convention

- Use lowercase with hyphens: `my-application.yaml`
- ConfigMap name: `dashboard-app-<name>`
- Dashboard UID: `app-<name>`

## Testing Dashboards

After applying, verify the dashboard loaded:
```bash
kubectl get configmaps -n observability -l grafana_dashboard=1 | grep dashboard-app
kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard
```
