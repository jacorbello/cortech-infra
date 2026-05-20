# Outreach DB Recovery

The outreach Postgres database lives on LXC 114 (192.168.1.83). This runbook covers restoring from backup after data loss or corruption.

## Daily backups location

Pg dumps land at `s3://cortech/db-backups/outreach/<YYYY-MM-DD>.sql.gz` on MinIO LXC 123 (192.168.1.x — see `docs/inventory.md`). Retention is 30 days.

## Restore procedure

### 1. Identify the dump

```bash
mc ls cortech/db-backups/outreach/ | tail -5
```

Pick the most recent dump older than the corruption point. If you don't know when the corruption occurred, restore to a separate name (`outreach_restore`) and inspect before swapping.

### 2. Download

```bash
mc cp cortech/db-backups/outreach/2026-05-19.sql.gz /tmp/
```

### 3. Drop the DB (destructive — confirm before running)

`sudo` is not installed in LXC 114; use `su postgres -c` instead. Also, anything connected to the `outreach` DB must be disconnected before DROP succeeds — that includes any n8n executions in flight.

```bash
# Stop n8n briefly so it isn't reconnecting
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- systemctl stop n8n'"

# Drop and recreate
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -c 'DROP DATABASE IF EXISTS outreach;'\""
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -c 'CREATE DATABASE outreach;'\""
ssh root@192.168.1.52 "pct exec 114 -- su postgres -c \"psql -d outreach -c 'GRANT ALL ON SCHEMA public TO outreach_admin;'\""
```

### 4. Restore

```bash
ADMIN_URL=$(infisical secrets get OUTREACH_DB_ADMIN_URL --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --plain)
gunzip -c /tmp/2026-05-19.sql.gz | psql "$ADMIN_URL"
```

### 5. Verify the trigger is present

The `enforce_approval_match` trigger is the load-bearing safety primitive of the outreach pipeline. Without it, the publish path can be tricked into sending content that was never approved. After restore, confirm it's wired:

```bash
psql "$ADMIN_URL" -c "\df+ enforce_approval_match"
psql "$ADMIN_URL" -c "\d publish_jobs"  # confirm 'trg_enforce_approval_match' is listed
```

### 6. Run the trigger enforcement tests

```bash
cd apps/outreach-schema && ./db/tests/run_tests.sh
```

All 4 fixture tests must pass before considering the restore complete.

### 7. Restart n8n

```bash
ssh root@192.168.1.52 "ssh root@192.168.1.80 'pct exec 112 -- systemctl start n8n'"
```

Watch the n8n executions log for a few minutes to confirm workflows pick back up cleanly.

## Partial restore (recovering specific rows without dropping the DB)

If you only need a few rows back (e.g., deleted approvals), restore into a separate database and copy across:

```bash
psql -h 192.168.1.83 -U outreach_admin -d postgres -c "CREATE DATABASE outreach_restore;"
gunzip -c /tmp/2026-05-19.sql.gz | psql -h 192.168.1.83 -U outreach_admin -d outreach_restore

# Inspect / copy via dblink or pg_dump | psql with row-level filters
```

Drop `outreach_restore` when done.

## Backup setup (one-time)

If backups stop landing in MinIO, check:
- The pg_dump cron on the Proxmox master (or wherever it runs) — search for `outreach` in `crontab -l` on each node
- MinIO bucket permissions (`mc admin policy` against `cortech/db-backups/outreach/`)
- Disk space on the source node and on LXC 123
