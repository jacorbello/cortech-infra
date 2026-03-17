# NGINX IP Whitelist Design

**Date:** 2026-03-17
**Status:** Approved

## Overview

Add a reusable IP whitelist mechanism to the NGINX reverse proxy (LXC 100) so designated services can be restricted to specific IP addresses. Non-whitelisted IPs receive a silent 444 (connection drop). Whitelist files are git-managed in this repo and deployed via GitHub Actions using the self-hosted ARC runner.

## Goals

- Restrict external access to sensitive services (initially: `osint.corbello.io`)
- Reusable pattern — adding a new protected service is a two-file change
- Operator-friendly management via GitHub Actions `workflow_dispatch` (add and remove IPs)
- No secrets committed to the repo

## Non-Goals

- Per-path IP restrictions (service-level granularity is sufficient)
- IP allowlist UI or dashboard
- Traefik-layer enforcement (NGINX proxy layer is the right place)
- IPv6 support — `default 0;` in each `geo` block will block IPv6 traffic; this is acceptable as `osint.corbello.io` is IPv4-only through the LXC proxy

## Architecture

### NGINX `geo` Block — Per-Service Variables

Each protected service gets its own `geo` variable (`$allowed_osint`, `$allowed_trading`, etc.) defined in `proxy/conf.d/whitelist.conf`. This ensures that IPs added for one service are never silently allowed on another.

`proxy/conf.d/whitelist.conf` is picked up automatically via the existing `include /etc/nginx/conf.d/*.conf;` in `nginx.conf` (confirmed on LXC 100, nginx/1.18.0).

**`whitelist.conf`:**
```nginx
# Global IPs shared across all protected services
# (populated via whitelist-global.conf)

# Per-service geo variables — add a new block when onboarding a new service
geo $allowed_osint {
    default 0;
    include /etc/nginx/conf.d/whitelist-global.conf;
    include /etc/nginx/conf.d/whitelist-osint-ips.conf;
}
```

Adding a second service (e.g., `minio-console`) means adding a new `geo $allowed_minio_console` block to `whitelist.conf` and a new `whitelist-minio-console-ips.conf` file. The GitHub Action manages only the IP files — `whitelist.conf` itself is edited manually when onboarding a new service.

### File Structure

```
proxy/
  conf.d/
    whitelist.conf                   # geo variable definitions (one block per protected service)
    whitelist-global.conf            # IPs allowed on ALL protected services
    whitelist-osint-ips.conf         # IPs allowed only on osint.corbello.io
  sites/
    osint.corbello.io.conf           # adds $allowed_osint check to location block
```

**`whitelist-global.conf` / `whitelist-<service>-ips.conf`** (bare IP entries, one per line):
```
1.2.3.4  1;  # home network
5.6.7.8  1;  # vpn exit
# no entries
```

Files must always contain at least a comment placeholder (`# no entries`) so NGINX does not fail on an empty include.

### Protected Server Block

```nginx
location / {
    if ($allowed_osint = 0) { return 444; }
    proxy_pass http://192.168.1.90:30278;
    ...
}
```

> **Note:** `if` inside a `location` block is generally dangerous in NGINX ("if is evil"). For a `return`-only `if` block this is safe, but the `if` block must contain **only** `return 444;` — no other directives. Do not add logging, headers, or proxy directives inside the `if` block.

### Adding a New Protected Service (Manual Onboarding)

1. Create `proxy/conf.d/whitelist-<service>-ips.conf` with a `# no entries` placeholder
2. Add a `geo $allowed_<service>` block to `proxy/conf.d/whitelist.conf` (includes global + service IPs)
3. Add `if ($allowed_<service> = 0) { return 444; }` to the service's server block in `proxy/sites/`
4. Add the service name to the `service` input choices in both GitHub Actions workflows

## ARC Runner for cortech-infra

A new `RunnerDeployment` is added to `k8s/actions-runner-system/cortech-infra-runner.yaml`:

- **Repo:** `jacorbello/cortech-infra`
- **Label:** `cortech-infra-deploy`
- **Replicas:** 1
- **Namespace:** `actions-runner-system`
- **Resources:** Match `osint-core-runner` profile — requests: `cpu: 200m, memory: 256Mi, ephemeral-storage: 1Gi`; limits: `cpu: 1, memory: 1Gi, ephemeral-storage: 4Gi`

### SSH Access to LXC 100

The runner SSHes into `root@192.168.1.100` to rsync whitelist files and reload NGINX.

- A dedicated `ed25519` keypair is created once (never committed to the repo)
- Private key and `known_hosts` stored together as a K8s Secret (`cortech-infra-proxy-ssh-key`) in `actions-runner-system`
- Secret mounted into the runner pod at `/secrets/` with `defaultMode: 0600`
- SSH and rsync commands in the workflow pass `-i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts` explicitly — this avoids any conflict with the ARC runner image's home directory setup
- Public key added to `/root/.ssh/authorized_keys` on LXC 100
- Host key verification: `known_hosts` is pre-populated via `ssh-keyscan` and stored in the Secret. This protects against a LAN MitM substituting malicious config.

**Relevant `RunnerDeployment` spec fields:**
```yaml
volumes:
  - name: proxy-ssh-key
    secret:
      secretName: cortech-infra-proxy-ssh-key
      defaultMode: 0600
volumeMounts:
  - name: proxy-ssh-key
    mountPath: /secrets
    readOnly: true
```

No `initContainer` is required — keys are mounted at `/secrets/` (not `~/.ssh/`), avoiding any home directory conflicts with the ARC runner image.

**`dockerdContainerResources`:** Intentionally omitted — this runner does not build Docker images. If LimitRange policies are in place on the cluster, add appropriate defaults.

**One-time secret creation:**
```bash
ssh-keyscan -H 192.168.1.100 > /tmp/known_hosts
kubectl create secret generic cortech-infra-proxy-ssh-key \
  --from-file=id_ed25519=/path/to/private-key \
  --from-file=known_hosts=/tmp/known_hosts \
  -n actions-runner-system
```

## GitHub Actions Workflows

Both workflows live in `.github/workflows/` in the `cortech-infra` repo and run on the `cortech-infra-deploy` self-hosted runner.

**Permissions:** Both workflows declare `permissions: contents: write` and use the built-in `GITHUB_TOKEN` for git push — no PAT or deploy key required. The repo's Actions settings must permit workflow write access (default for non-forked repos).

### `add-ip-whitelist.yml`

**Trigger:** `workflow_dispatch`

**Inputs:**

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `ip` | string | yes | IPv4 address to allow (e.g. `203.0.113.5`). CIDRs and IPv6 are out of scope. |
| `service` | choice | yes | `global`, `osint` (extend as new services are onboarded) |
| `reason` | string | yes | Short description — used in commit message and as inline comment |

**Steps:**
1. Checkout repo (`actions/checkout` with `GITHUB_TOKEN`, `persist-credentials: true`)
2. Validate `ip` matches IPv4 regex — fail fast with a clear error message if invalid
3. Check for duplicate — if the IP already appears in the target file, skip the commit and exit 0 with a notice
4. Append `<ip>  1;  # <reason>` to `proxy/conf.d/whitelist-<service>-ips.conf` (or `whitelist-global.conf` if service is `global`)
5. Commit & push: `chore(proxy): allow <ip> on <service> — <reason>`
6. rsync `proxy/conf.d/whitelist*.conf` to `root@192.168.1.100:/etc/nginx/conf.d/` using `-e "ssh -i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts"`
7. Run `nginx -t` on LXC 100 via `ssh -i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts root@192.168.1.100 "nginx -t"` — fail the workflow immediately if config test fails (live traffic is unaffected)
8. Run `nginx -s reload` on LXC 100 via the same SSH invocation

### `remove-ip-whitelist.yml`

**Trigger:** `workflow_dispatch`

**Inputs:** Same as add (`ip`, `service`, `reason`)

**Steps:**
1. Checkout repo
2. Validate `ip` is an exact-match IPv4 entry present in the target file — fail with a clear error if not found. CIDR range entries are out of scope for this workflow and are not removed.
3. Remove the exact line matching `^<ip>\s` from `proxy/conf.d/whitelist-<service>-ips.conf` (or `whitelist-global.conf`)
4. Commit & push: `chore(proxy): remove <ip> from <service> — <reason>`
5. rsync + `nginx -t && nginx -s reload` (same SSH invocation as add workflow)

## Deployment Notes

- rsync scope is limited to `whitelist*.conf` files only — other nginx configs are not touched by the workflows
- `nginx -t` is always run before `nginx -s reload` — a bad config file will fail the workflow without disrupting live traffic
- **Rollback (config errors):** If a bad commit causes `nginx -t` to fail, revert the offending commit locally and re-run the deploy workflow (which will rsync the reverted files and attempt reload)
- **Rollback (logical errors):** If a syntactically valid but wrong IP is added (e.g. a typo), `nginx -t` will pass and the entry will be live. Use the `remove-ip-whitelist` workflow to remove it — this is the primary rollback tool for incorrect-but-valid entries

## Testing

- After initial deploy, verify a non-whitelisted IP receives no response (connection timeout) on `osint.corbello.io`
- Verify a whitelisted IP can reach the service normally
- Run `add-ip-whitelist` workflow; confirm the IP appears in the file and nginx reloads cleanly
- Run `remove-ip-whitelist` workflow; confirm the IP is removed and nginx reloads cleanly
- Attempt to add a duplicate IP — confirm workflow exits with a notice and no commit
- Attempt to remove a non-existent IP — confirm workflow fails with a clear error
- Confirm that an IP added to `whitelist-osint-ips.conf` is **not** accessible on any other future protected service
