# Arboretum Health WordPress

Self-hosted WordPress site exposed at <https://arboretum-health.corbello.io>.

Namespace: `arboretum-health`. Deployed via Kustomize + ArgoCD (`apps/wordpress/argocd-application.yaml`), with secrets synced from Infisical.

## Pinned versions

| Component | Image |
|---|---|
| WordPress | `wordpress:6.9.4-php8.3-apache` |
| MariaDB | `mariadb:11.8.6` |

Bump these in `base/wordpress/deployment.yaml` / `base/mariadb/deployment.yaml`, commit, and ArgoCD will sync.

## Layout

| File | Resource |
|------|----------|
| `base/namespace.yaml` | Namespace |
| `base/infisical-secret.yaml` | InfisicalSecret syncing `/arboretum-health` (dev env) into Secret `arboretum-health-secrets` |
| `base/mariadb/{pvc,service,deployment}.yaml` | MariaDB (1 replica, Recreate, 5Gi PVC on `nfs-node3`) |
| `base/wordpress/{pvc,service,deployment,ingress}.yaml` | WordPress (1 replica, Recreate, 10Gi `wp-content` PVC on `nfs-node3`, plain Traefik Ingress) |
| `base/kustomization.yaml` | Bundle |
| `overlays/production/kustomization.yaml` | Production overlay (currently a thin wrapper over base) |
| `argocd-application.yaml` | ArgoCD Application pulling `overlays/production` from `main` |

The Ingress has no TLS block — TLS terminates upstream on the NGINX proxy (LXC 100). Traefik sees plain HTTP and routes by Host header.

## Required secrets in Infisical

Set these under project `c00e26a9-9389-4cc8-9b74-75f936dfeb81`, env `dev`, path `/arboretum-health`:

| Key | Notes |
|---|---|
| `MARIADB_ROOT_PASSWORD` | Random ≥32 chars |
| `MARIADB_PASSWORD` | Password for the `wordpress` DB user |
| `WORDPRESS_DB_PASSWORD` | Must equal `MARIADB_PASSWORD` |
| `WORDPRESS_AUTH_KEY` | From `curl -s https://api.wordpress.org/secret-key/1.1/salt/` |
| `WORDPRESS_SECURE_AUTH_KEY` | (same source) |
| `WORDPRESS_LOGGED_IN_KEY` | (same source) |
| `WORDPRESS_NONCE_KEY` | (same source) |
| `WORDPRESS_AUTH_SALT` | (same source) |
| `WORDPRESS_SECURE_AUTH_SALT` | (same source) |
| `WORDPRESS_LOGGED_IN_SALT` | (same source) |
| `WORDPRESS_NONCE_SALT` | (same source) |

The `secret-key/1.1/salt/` endpoint returns all eight key/salt lines in one PHP-formatted block — copy each quoted value into the matching Infisical key.

## Public reachability

NGINX site config: `proxy/sites/arboretum-health.corbello.io.conf` (deployed onto LXC 100).

One-time setup on LXC 100 (run from cortech master):

```bash
# 1. Copy the site config into the proxy LXC
pct push 100 /root/cortech-infra/proxy/sites/arboretum-health.corbello.io.conf \
  /etc/nginx/sites-available/arboretum-health.corbello.io.conf

pct exec 100 -- ln -sf \
  /etc/nginx/sites-available/arboretum-health.corbello.io.conf \
  /etc/nginx/sites-enabled/

# 2. Issue Let's Encrypt cert (HTTP-01 — needs DNS + port 80 reachable)
pct exec 100 -- certbot --nginx -d arboretum-health.corbello.io \
  --non-interactive --agree-tos -m jacorbello@gmail.com

# 3. Validate and reload
pct exec 100 -- nginx -t
pct exec 100 -- nginx -s reload
```

Renewal is handled by the existing certbot cron/systemd timer on LXC 100; no per-domain work needed after issuance.

## Upgrades

1. Pick a new tag from <https://hub.docker.com/_/wordpress/tags?name=php8.3-apache> (or `mariadb`).
2. Bump `image:` in the relevant deployment.
3. `git commit` + push to `main`. ArgoCD auto-syncs.
4. WordPress core auto-migrates the DB on first request after the image bump (no manual migration step).

## Notes

- **Single replica** for both pods — PVCs are RWO. Going multi-replica would require sharing `wp-content` across replicas (RWX) or using an object-store offload plugin for media.
- **wp-content only** is volume-mounted; the WordPress core lives in the container image. Bumping the image upgrades the core; plugins/themes/uploads survive in the PVC.
- **No node pinning.** Unlike SonarQube, the PVCs use `nfs-node3` (NFS CSI) so pods can move between K3s nodes.
- **TLS scheme propagation** — `WORDPRESS_CONFIG_EXTRA` in the deployment forces `$_SERVER['HTTPS']='on'` when the upstream `X-Forwarded-Proto` header says `https`, so WP generates correct https:// links behind the LXC 100 terminator.

## First-time install

Once everything is up:

1. Browse to <https://arboretum-health.corbello.io>.
2. Complete the install wizard: site title, admin user, password, email.
3. Verify a media upload + theme change persists across `kubectl -n arboretum-health rollout restart deploy/wordpress`.
