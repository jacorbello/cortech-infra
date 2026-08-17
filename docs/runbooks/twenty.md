# Twenty CRM (crm.plotlens.ai)

Self-hosted [Twenty](https://github.com/twentyhq/twenty) on K3s, namespace `crm`,
GitOps-managed from `apps/twenty/`.

| | |
|---|---|
| URL | https://crm.plotlens.ai |
| Namespace | `crm` (Deployments `twenty-server`, `twenty-worker`) |
| Image | `twentycrm/twenty:v2.31.1` (pinned in `apps/twenty/base/*-deployment.yaml`) |
| Postgres | LXC 114 — `192.168.1.83:5432/twenty`, role `twenty` (owns the DB) |
| Redis | `192.168.1.86:6379` DB 3 |
| Attachments | PVC `twenty-data`, 20Gi RWX on `nfs-node3` |
| TLS | certbot lineage `crm.plotlens.ai` on proxy LXC 100 |
| ArgoCD | app `twenty`, auto-sync + selfHeal |

## Secrets

Infisical project `db72a923-…` (PlotLens), env `dev`, path `/twenty`. Synced into
the `twenty-secrets` Secret by `InfisicalSecret`; both Deployments `envFrom` it.

| Key | Notes |
|---|---|
| `PG_DATABASE_URL` | `postgres://twenty:<pw>@192.168.1.83:5432/twenty` |
| `REDIS_URL` | `redis://192.168.1.86:6379/3` |
| `APP_SECRET` | `openssl rand -base64 32` |
| `ENCRYPTION_KEY` | `openssl rand -base64 32` |

**`ENCRYPTION_KEY` is unrecoverable.** It encrypts OAuth tokens, TOTP secrets and
app variables at rest. Lose it and every DB secret is garbage — the CRM records
survive, the integrations do not. To rotate: put the old value in
`FALLBACK_ENCRYPTION_KEY`, set the new one in `ENCRYPTION_KEY`, restart, then drop
the fallback once re-encryption has run.

Non-secret config lives in the `twenty-config` ConfigMap and, because
`IS_CONFIG_VARIABLES_IN_DB_ENABLED=true`, in the DB — most settings are editable at
**Settings → Admin Panel → Configuration Variables** (effective within ~15s, no restart).

## First-time setup

1. DB + role on LXC 114:
   ```sql
   CREATE ROLE twenty LOGIN PASSWORD '<pw>';
   CREATE DATABASE twenty OWNER twenty;
   -- then, connected to the twenty database, as postgres:
   CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
   CREATE EXTENSION IF NOT EXISTS "unaccent";
   ```
   Run it through the credential-less path:
   `ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c 'psql -f /tmp/x.sql'"`.

   Twenty's `setup-db` creates the `public` and `core` schemas plus one schema per
   workspace, so `twenty` must own the database. `uuid-ossp` and `unaccent` are
   *trusted* extensions in PG 15, so the owner could install them itself — we
   pre-create them as `postgres` anyway so the app never needs superuser. FDW
   extensions (`postgres_fdw`, `wrappers`, `mysql_fdw`) are only touched when
   `IS_FDW_ENABLED=true`; leave it off and PG 15.19 on LXC 114 is sufficient
   (upstream's own Postgres image is also PG 15).
2. Populate the four Infisical keys above.
3. DNS: `crm.plotlens.ai` CNAME → `corbello.ddns.net`.
4. `kubectl apply -f apps/twenty/argocd-application.yaml` (once, by hand).
5. On LXC 100: place `proxy/sites/crm.plotlens.ai.conf`, then
   `certbot --nginx -d crm.plotlens.ai`. Its **own** lineage — do not bolt it onto
   the `plotlens.ai` cert; one dead SAN wedges renewal for the whole bundle.
6. Visit the URL and sign up — the first user becomes workspace admin.
   Single-workspace mode, so no second workspace can be created.

## Health checks

```bash
kubectl -n crm get pods
kubectl -n crm logs deploy/twenty-server --tail=50
kubectl -n crm get secret twenty-secrets -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2
curl -H 'Host: crm.plotlens.ai' -I http://192.168.1.90:30278/    # via Traefik
curl -I https://crm.plotlens.ai                                   # public
```

## Backup / restore

Dump from LXC 114 (schema-per-workspace, so always dump the whole DB):

```bash
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c 'pg_dump -Fc twenty' " > twenty-$(date +%F).dump
# restore
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c 'dropdb twenty && createdb -O twenty twenty'"
ssh root@192.168.1.52 "pct exec 114 -- su - postgres -c 'pg_restore -d twenty'" < twenty-<date>.dump
```

Store dumps in MinIO alongside the other Postgres dumps. Attachments live on the
NFS PVC (`nfs-node3`, reclaim policy `Retain`) — back the share up with the rest of
the node3 NFS export, not separately.

## Upgrade

1. Take a DB dump (above). Migrations are not reversible.
2. Bump the tag in **both** `server-deployment.yaml` and `worker-deployment.yaml`
   to the new `twenty/vX.Y.Z` release, commit, merge — ArgoCD syncs.
3. The server runs migrations on boot; the worker has them disabled. Watch
   `kubectl -n crm logs deploy/twenty-server -f` until `/healthz` goes green.

## Known gotchas

- `strategy: Recreate` on the server is deliberate — a rolling update would run two
  versions of the migrator against one DB.
- PVC is `ReadWriteMany`: server and worker both mount `.local-storage`. RWO would
  pin them to one node and wedge the second pod.
- `SERVER_URL` must be the public HTTPS URL or secure cookies and OAuth callbacks
  break in non-obvious ways (login loops).
- Local logic functions / code interpreter are unsandboxed in self-hosted mode.
  Leave them off unless you trust every workspace member.
