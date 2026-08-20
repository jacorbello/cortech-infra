# Twenty CRM (crm.plotlens.ai)

Self-hosted [Twenty](https://github.com/twentyhq/twenty) on K3s, namespace `crm`,
GitOps-managed from `apps/twenty/`.

| | |
|---|---|
| URL | https://crm.plotlens.ai |
| Namespace | `crm` (Deployments `twenty-server`, `twenty-worker`) |
| Image | `twentycrm/twenty:v2.31.1` (pinned in `apps/twenty/base/*-deployment.yaml`) |
| Postgres | LXC 114 — `192.168.1.83:5432/twenty`, role `twenty` (owns the DB) |
| Redis | dedicated `twenty-redis` StatefulSet in `crm` (5Gi `nfs-node3` PVC, AOF on) |
| Attachments | PVC `twenty-data`, 20Gi RWX on `nfs-node3` |
| TLS | certbot lineage `crm.plotlens.ai` on proxy LXC 100 |
| ArgoCD | app `twenty`, auto-sync + selfHeal |

## Secrets

Infisical project `db72a923-…` (PlotLens), env `dev`, path `/twenty`. Synced into
the `twenty-secrets` Secret by `InfisicalSecret`; both Deployments `envFrom` it.

`REDIS_URL` is *not* a secret and lives in the ConfigMap — the in-cluster Redis has
no password. The shared Redis at `.86` was rejected: it requires auth and already
carries the Infisical workers' traffic, and `apps/postiz` sets the same precedent.

| Key | Notes |
|---|---|
| `PG_DATABASE_URL` | `postgres://twenty:<pw>@192.168.1.83:5432/twenty` |
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
curl -H 'Host: crm.plotlens.ai' -I http://192.168.1.110/    # via Traefik
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

Automated: `scripts/pg-backup.sh` runs on the Proxmox master via the
`pg-backup.timer` systemd timer (daily 03:15, `Persistent=true` so a missed run
catches up after a reboot). It dumps `twenty` and `outreach` through `pct exec`,
so no DB password lives in cron, and writes to node3's dedicated
`storage-pool/backups` dataset mounted at `/mnt/db-backups`. 14-day retention;
each dump is `gzip -t`-verified and deleted if empty, because a truncated dump
that looks like a backup is worse than none.

```bash
systemctl list-timers pg-backup.timer   # next run
journalctl -u pg-backup.service -n 30   # last run
ls -lh /mnt/db-backups/twenty/          # the dumps themselves
```

Attachments live on the
NFS PVC (`nfs-node3`, reclaim policy `Retain`) — back the share up with the rest of
the node3 NFS export, not separately.

## Waitlist sync (Clerk -> Twenty)

`scripts/clerk-waitlist-to-twenty.py` mirrors Clerk waitlist entries into Twenty as
People. Idempotent — it matches on the custom `clerkWaitlistId` field, so re-runs
only create what's missing and patch `waitlistStatus`/`waitlistJoinedAt` when they
change. Human edits to names survive.

```bash
scripts/clerk-waitlist-to-twenty.py --dry-run   # always look first
scripts/clerk-waitlist-to-twenty.py
```

Credentials are read from Infisical at runtime (`/twenty/API_KEY` in `dev`,
`CLERK_SECRET_KEY` in **`prod`** — the `dev` one is `sk_test_` and holds only QA
users). Custom Person fields it depends on: `clerkWaitlistId`, `waitlistJoinedAt`,
`waitlistStatus`, `signupSource`.

Known gaps:

- Clerk's waitlist stores only email + timestamp, so `signupSource` is `UNKNOWN`
  for every pre-existing entry. Attribution needs UTM capture on the plotlens.ai
  waitlist form; nothing here can backfill it.
- Clerk keeps `status: pending` even after an invite is sent, so the script reads
  the nested `invitation.status` to decide `INVITED`.
- No Companies are created. The audience is individuals (38 of the first 47 are
  free-mail), so domain grouping would manufacture junk records.

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
