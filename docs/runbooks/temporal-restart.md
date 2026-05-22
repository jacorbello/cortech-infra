# Temporal Restart

Temporal is deployed in the `plotlens-marketing` namespace via the ArgoCD `temporal` Application (chart `temporalio/temporal` v0.74.0). Postiz embeds 28 Temporal worker processes that connect to this server on `temporal-frontend.plotlens-marketing.svc.cluster.local:7233`.

## When to restart

- Temporal Web UI (`https://temporal.corbello.io`) unreachable.
- Postiz logs show "Temporal connection failed" or "no available host(s)".
- Alertmanager fires `TemporalPodCrashLooping`.
- After a chart values change in `apps/temporal/values.yaml`.
- After rotating `TEMPORAL_DATABASE_PASSWORD` in Infisical.

## Restart procedure

### Soft restart (rolling, preferred)

```bash
ssh root@192.168.1.52 "kubectl rollout restart deployment -n plotlens-marketing -l app.kubernetes.io/name=temporal"
ssh root@192.168.1.52 "kubectl rollout status deployment -n plotlens-marketing -l app.kubernetes.io/name=temporal --timeout=180s"
```

### Hard restart (delete pods)

```bash
ssh root@192.168.1.52 "kubectl delete pod -n plotlens-marketing -l app.kubernetes.io/name=temporal"
```

ArgoCD reconciles every ~3 minutes; the Deployments will recreate the pods immediately (Deployment controller, not ArgoCD, is the recreator).

### Full re-sync via ArgoCD

If a values change isn't taking effect, force a refresh + sync:

```bash
ssh root@192.168.1.52 "kubectl patch application temporal -n argocd --type merge -p '{\"operation\":{\"sync\":{}}}'"
```

Or via the ArgoCD UI: `https://argocd.corbello.io` → `temporal` application → Sync.

## Verification after restart

1. All temporal pods Running:
   ```bash
   ssh root@192.168.1.52 "kubectl get pods -n plotlens-marketing -l app.kubernetes.io/name=temporal"
   ```
2. Temporal Web UI reachable:
   ```bash
   curl -sI https://temporal.corbello.io/ | head -3
   ```
3. Postiz log shows Temporal connection recovery:
   ```bash
   ssh root@192.168.1.52 "kubectl logs -n plotlens-marketing -l app=postiz --tail=50 | grep -i temporal"
   ```
4. Confirm the `default` Temporal namespace still exists (the chart only creates `temporal-system`; we manually created `default` during Phase 2 T9):
   ```bash
   ssh root@192.168.1.52 "kubectl -n plotlens-marketing exec deploy/temporal-admintools -- temporal operator namespace list 2>/dev/null | head"
   ```
   If `default` is missing after a hard restart (DB wipe etc.), recreate it:
   ```bash
   ssh root@192.168.1.52 "kubectl -n plotlens-marketing exec deploy/temporal-admintools -- temporal operator namespace create --namespace default --retention 7d"
   ```

## What survives a restart

- All workflow state persists in the `temporal` and `temporal_visibility` Postgres DBs on LXC 114 (`192.168.1.83`).
- Active workflow executions resume from their last checkpoint after pods come back.
- Scheduled posts in Postiz are NOT lost (Postiz stores them in its own `postiz` DB; Temporal just re-runs the schedule).

## What does NOT survive

- In-flight HTTP requests at the moment of pod death.
- Workflow runs that were mid-execution: Temporal retries them automatically on resume.

## When the DB is the problem

If Temporal can't connect to Postgres at all (`failed to connect to ...:5432`):

1. Check LXC 114 reachability:
   ```bash
   ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
   psql "$ADMIN_URL" -c "SELECT 1;"
   ```
   Reminder: LXC 114 Postgres is at `192.168.1.83`, NOT `.114`.
2. Check the temporal_app password matches Infisical:
   ```bash
   infisical secrets get TEMPORAL_DATABASE_PASSWORD --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/temporal --plain
   ```
3. The `temporal-secrets` K8s Secret is synced by the Infisical Operator (every 60s). If stale, force a re-sync:
   ```bash
   ssh root@192.168.1.52 "kubectl delete infisicalsecret temporal-secrets -n plotlens-marketing"
   ```
   ArgoCD recreates the `InfisicalSecret` on the next reconciliation, or apply manually from `apps/temporal/extras/infisical-secret.yaml`.
4. If the connection is fine but auth fails, the password in the DB role drifted. Reset it:
   ```bash
   ssh root@192.168.1.52 'ssh root@192.168.1.80 "pct exec 114 -- su postgres -c \"psql -c \\\"ALTER USER temporal_app WITH PASSWORD <newpw>;\\\"\""'
   infisical secrets set TEMPORAL_DATABASE_PASSWORD=<newpw> --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/temporal
   ssh root@192.168.1.52 "kubectl delete infisicalsecret temporal-secrets -n plotlens-marketing"
   ```

## Persistent disasters

If the Temporal DBs are corrupted beyond repair:

1. Stop ArgoCD from re-syncing Temporal: `argocd app set temporal --sync-policy none` (or pause the Application in the UI).
2. Drop and recreate the two Temporal DBs on LXC 114:
   ```sql
   DROP DATABASE temporal;
   DROP DATABASE temporal_visibility;
   CREATE DATABASE temporal OWNER temporal_app;
   CREATE DATABASE temporal_visibility OWNER temporal_app;
   ```
3. Re-enable ArgoCD sync. The chart's setup Job will recreate the schema (`schema.setup.enabled=true` in `apps/temporal/values.yaml`).
4. Manually recreate the `default` Temporal namespace (see "Verification after restart" step 4).
5. Lost data: in-flight workflows, schedules, history. Postiz's own DB still has its scheduled posts and will republish them on its next worker tick.
