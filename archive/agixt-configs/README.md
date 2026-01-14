# AGiXT Decommissioning Archive

**Date:** 2026-01-12
**Reason:** Replaced by Dify (https://dify.corbello.io)

## What was decommissioned

| Service | Container | Status |
|---------|-----------|--------|
| AGiXT | agixt | Stopped (container preserved) |
| AGiXT DB | agixt-db | Stopped (container preserved) |
| RAG API | rag-api | Stopped (container preserved) |
| Meilisearch | meilisearch | Stopped (container preserved) |
| LibreChat | librechat | Stopped (container preserved) |
| MongoDB | mongodb | Stopped (container preserved) |

## What remains running on PCT 121

| Service | Purpose |
|---------|---------|
| tools-gateway | Dify integration for secure actions |
| discord-bridge | Discord notifications |
| promtail | Log shipping to Loki |

## Archived configs

- `agixt-backup-20260112.tar.gz` - Contains:
  - `/opt/jarvis/agents/` - AGiXT agent configurations
  - `/opt/jarvis/agixt-extensions/` - Custom AGiXT extensions
  - `/opt/jarvis/scheduler/` - Cron task definitions
  - `/opt/jarvis/librechat.yaml` - LibreChat config
  - `/opt/jarvis/projects.yaml` - Project definitions
  - `/opt/jarvis/SYSTEM_CONTRACT.md` - System contract
  - `/opt/jarvis/docker-compose.yml` - Full stack compose

## Rollback procedure

If Dify fails and you need to restore AGiXT/LibreChat:

```bash
# 1. Start the containers
pct exec 121 -- docker start mongodb librechat agixt-db agixt rag-api meilisearch

# 2. Restore crontab (if needed)
pct exec 121 -- crontab /opt/jarvis/scheduler/crontab

# 3. Update proxy to point chat.corbello.io back to LibreChat
# Edit /root/repos/infrastructure/proxy/sites/chat.corbello.io.conf
# Change proxy_pass to http://192.168.1.117:3080
```

## Full removal (after stability period)

After 2-4 weeks of stable Dify operation:

```bash
# Remove stopped containers and volumes
pct exec 121 -- docker rm agixt agixt-db rag-api meilisearch librechat mongodb
pct exec 121 -- docker volume prune

# Remove AGiXT directories (optional, keep archive)
# pct exec 121 -- rm -rf /opt/jarvis/agixt-extensions /opt/jarvis/agents
```
