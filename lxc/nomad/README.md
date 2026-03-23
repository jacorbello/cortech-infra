# Project N.O.M.A.D. — LXC 124

[Project N.O.M.A.D.](https://github.com/Crosstalk-Solutions/project-nomad) is a self-contained, offline-first knowledge and education server. It bundles AI chat (Ollama + Qdrant), offline Wikipedia/ebooks (Kiwix), Khan Academy courses (Kolibri), offline maps (ProtoMaps), data tools (CyberChef), and local note-taking (FlatNotes) — all accessible through a browser-based management UI called the Command Center.

## Container Details

| Field | Value |
|-------|-------|
| VMID | 124 |
| Hostname | nomad |
| IP | 192.168.1.150/24 |
| Gateway | 192.168.1.1 |
| Resources | 4 vCPU, 4 GiB RAM, 32 GiB disk |
| Features | nesting=1, keyctl=1 (Docker-in-LXC) |

## Deploy

1. Create the LXC container using the spec in `../../pct/124-nomad.conf`
2. Start the container and install Docker:
   ```bash
   pct start 124
   pct exec 124 -- bash -c "apt update && apt install -y curl && curl -fsSL https://get.docker.com | sh"
   ```
3. Copy compose files and configure environment:
   ```bash
   pct exec 124 -- mkdir -p /opt/project-nomad
   # Copy docker-compose.yaml, watchtower-compose.yaml, and .env.example into /opt/project-nomad/
   # Then on the container:
   cd /opt/project-nomad
   cp .env.example .env
   # Edit .env and fill in all required values (APP_KEY, DB_PASSWORD, MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD, URL)
   ```
4. Start services:
   ```bash
   docker compose up -d
   docker compose -f watchtower-compose.yaml up -d
   ```

## Environment Variables

Copy `.env.example` to `.env` and fill in real values before starting. The minimum required fields are:

- `APP_KEY` — random string, minimum 16 characters
- `DB_PASSWORD` / `MYSQL_PASSWORD` / `MYSQL_ROOT_PASSWORD` — must match between services
- `URL` — the URL you'll access the UI at (e.g. `http://192.168.1.150:8080`)

## Auto-Updates

Watchtower runs as a separate compose stack (`watchtower-compose.yaml`) and polls GHCR every hour for new images. It automatically pulls and restarts containers when updates are available, then cleans up old images.

## Access

- **Direct:** http://192.168.1.150:8080
- **Proxy (once configured):** https://nomad.corbello.io
- **Container logs (Dozzle):** http://192.168.1.150:9999
