# Traefik Ingress Migration

Move public ingress off NGINX on LXC 100 and onto the Traefik already running in
K3s, retiring the last single point of failure in front of every `*.corbello.io`
service.

Status: **planned, not started.** Written 2026-08-17.

## Why

Two problems share one root cause.

**LXC 100 is a SPOF.** Every public request for every hostname terminates there. If
that container dies, the whole homelab goes dark from the outside — Rancher, ArgoCD,
Harbor, Grafana, PlotLens, Home Assistant, all of it. Nothing about it is redundant.

**The repo can never own its config.** certbot rewrites the files in
`sites-available/` in place on renewal, so `proxy/sites/*.conf` in this repo are
copies that drift silently. The `conf.d/security.conf` split (PR #65) contains that
damage for shared policy, but the per-vhost files stay unownable for as long as
certbot manages them.

Traefik in K3s fixes both: it runs as a DaemonSet across nodes, and cert-manager
issues certs into Kubernetes Secrets that no process rewrites behind git's back.

**This is not urgent.** The current setup works, and PR #65 removed most of the
day-to-day drift pain. Do this when there is already reason to touch ingress.

## Current state

Verified 2026-08-17.

| Thing | State |
|-------|-------|
| Traefik `LoadBalancer` | `EXTERNAL-IP: <pending>` — reachable only on NodePorts 30278/30252 |
| cert-manager | Healthy, `letsencrypt-prod` ClusterIssuer ready 202 days |
| Existing ingress objects | 10 `Ingress` + 4 `IngressRoute` |
| kube-vip | Already a DaemonSet in `kube-system`, serving the API VIP `.90` |
| Router forwarding | 80/443 TCP → `192.168.1.100` only |
| DNS | Every public hostname CNAMEs to `corbello.ddns.net` (No-IP, kept current by `noip-duc` on LXC 100) |

## The blocker

Traefik has no external IP. Its Service sits `<pending>` because nothing allocates
one. This — not ingress configuration — is what stands between here and a cutover.

| Option | Verdict |
|--------|---------|
| **kube-vip in service mode** | **Chosen.** kube-vip is already deployed and understood here. Extending it to Service load balancers adds no new component. |
| MetalLB (L2) | Works, well-trodden, but duplicates what kube-vip already does in this cluster. |
| K3s ServiceLB (klipper) | Simplest to switch on, but binds node IPs — no single stable target, which makes the router's port-forward fragile as nodes come and go. |

Allocate a dedicated VIP outside the DHCP pool. **`192.168.1.89`** is free and
adjacent to the API VIP at `.90`. The pool is `.200-.250` (moved there after the
static-overlap outage — see `docs/network-reservations.md`), so `.89` is safe.

## Two classes of service

This is the finding that sizes the work. Most vhosts are already double-proxied:
NGINX → Traefik NodePort → pod. For those, migration is mostly deleting an NGINX
vhost.

### Class A — already have a Kubernetes ingress object (~12)

`argocd` · `grafana` · `harbor` · `infisical` · `rancher` · `sonarqube` ·
`plotlens.corbello.io` (+ `api.`) · `website.plotlens` · `microsoft.plotlens` ·
`postiz` · `postiz-webhooks` · `temporal`

Work per service: confirm the ingress resolves through the VIP, issue a cert via
cert-manager, delete the NGINX vhost. No new routing.

### Class B — backed by an LXC or VM, no ingress object (~8)

| Host | Backend |
|------|---------|
| `ha.corbello.io` | VM 101, `192.168.1.61:8123` |
| `keycloak.corbello.io` | LXC 121 |
| `minio.corbello.io`, `minio-console.corbello.io` | LXC 123 / `.118` |
| `n8n.corbello.io` | LXC 112 / `.81` |
| `nomad.corbello.io` | LXC 124 |
| `status.corbello.io` | LXC 120 (Uptime-Kuma) |
| `proxmox.corbello.io` | Proxmox UI on the master |

These need a `Service` with manual `Endpoints` (or `ExternalName`) pointing at the
LXC IP, plus an `IngressRoute`. This is the actual work of the migration.

Note `proxmox.corbello.io` deserves thought — routing the hypervisor UI through a
cluster that runs *on* that hypervisor creates a circular dependency during an
outage. Consider leaving it on a minimal direct path, or accept that it is
reachable by IP when things are broken.

## The ACME chicken-and-egg

cert-manager's `letsencrypt-prod` uses HTTP-01, which requires Let's Encrypt to
reach port 80 for the hostname being validated. Port 80 points at NGINX until the
final cutover. So certs cannot issue for a hostname *before* it moves, but the
hostname should not move *before* its cert exists.

**Resolution: proxy the ACME challenge path.** Add to each NGINX vhost being
migrated, ahead of its `location /`:

```nginx
location /.well-known/acme-challenge/ {
    proxy_pass http://192.168.1.89;
    proxy_set_header Host $host;
}
```

Let's Encrypt still reaches NGINX; NGINX hands the challenge to Traefik; cert-manager
completes it. Certs pre-issue per-service with no DNS credentials and no flag day.

**Rejected: DNS-01.** Cleaner in principle, but `corbello.io` is on Namecheap, which
cert-manager supports only through a third-party webhook solver. That is more new
surface than this problem justifies.

## Phases

Each phase is independently revertible and leaves the system serving traffic.

### Phase 1 — give Traefik a VIP

Enable kube-vip service mode, allocate `192.168.1.89` to the Traefik Service.
No traffic moves; NGINX still serves everything.

- **Verify:** `curl -H 'Host: rancher.corbello.io' http://192.168.1.89/` returns
  something from Traefik, and `kubectl get svc -n kube-system traefik` shows the
  external IP.
- **Rollback:** revert the Service annotation. Nothing depended on it.

### Phase 2 — prove the pattern on one low-stakes service

Use `status.corbello.io` (Uptime-Kuma, LXC 120) — it is Class B, so it exercises the
harder path, and nothing else depends on it.

Create the Service + Endpoints + IngressRoute, add the ACME challenge proxy to its
NGINX vhost, let cert-manager issue, then verify through the VIP with a hosts-file
override before any DNS or forwarding changes.

- **Verify:** cert `Ready=True`; the service answers over TLS through the VIP with a
  valid publicly-trusted chain.
- **Rollback:** delete the Kubernetes objects. NGINX never stopped serving.

### Phase 3 — migrate in batches, lowest stakes first

Suggested order: Class A internal tools (`sonarqube`, `grafana`, `argocd`) → Class B
internal (`n8n`, `nomad`, `minio`) → auth and registry (`keycloak`, `harbor`,
`rancher`) → product hostnames (`plotlens*`) last.

Each service stays dual-configured — NGINX vhost intact, ingress live — until
verified through the VIP.

- **Verify per batch:** every hostname answers through the VIP with a valid cert, and
  websocket-dependent services (Home Assistant, Rancher, ArgoCD) survive a real
  session, not just a `curl -I`.
- **Rollback:** the NGINX vhost is still there and still authoritative until Phase 4.

### Phase 4 — cutover

Repoint the router's 80/443 forward from `192.168.1.100` to `192.168.1.89`.

**This is the all-or-nothing moment** and the only one with real blast radius. Every
hostname moves at once, because they all CNAME to a single dynamic record behind a
single pair of port-forwards.

- **Verify:** every hostname from off-network (phone on cellular, not LAN — hairpin
  NAT will lie to you). Check certs, websockets, and the PlotLens product paths.
- **Rollback:** point the forward back at `.100`. NGINX config is untouched, so this
  is a sub-minute recovery. **Do not delete anything on LXC 100 during this phase.**

### Phase 5 — decommission

After a soak of at least a week with no fallbacks: strip the migrated vhosts, retire
certbot for those lineages, and shrink LXC 100 to what still needs it.

**`noip-duc` runs on LXC 100 and must survive.** It keeps `corbello.ddns.net` pointed
at the current WAN IP; if it stops, every hostname goes dark regardless of where
ingress lives. Either leave LXC 100 running for it alone, or move it first and verify
independently. See `noip-duc/`.

## Risks

| Risk | Mitigation |
|------|-----------|
| Cutover breaks everything at once | Port-forward revert is sub-minute; leave LXC 100 fully intact through Phase 4 |
| Websocket regressions (HA, Rancher, ArgoCD) | Test with real sessions per batch, not `curl -I` |
| `noip-duc` decommissioned with the proxy | Explicitly called out in Phase 5; verify DDNS independently before touching LXC 100 |
| Circular dependency on `proxmox.corbello.io` | Consider leaving it off the cluster path |
| Hairpin NAT masks failures during testing | Verify from off-network; LAN traffic reaches the proxy as `192.168.1.1` (router SNAT) and does not exercise the real path |
| Cert rate limits during bulk migration | Let's Encrypt allows 50 certs/week per registered domain — batch sizes here are well under, but use staging first if a batch has to be retried |

## Open questions

- Does `plotlens.ai` route through this proxy at all? It has an ingress object but no
  served NGINX vhost, which suggests it reaches the cluster another way. Resolve
  before migrating anything PlotLens-facing.
- Five repo vhosts are no longer served — `dify`, `osint`, `plotlens.ai`, `postal`,
  `wg`. Confirm which are genuinely decommissioned and delete them rather than
  migrating dead config. `make proxy-check` lists them.
- `wgdashboard` shares the `ha.corbello.io` certificate lineage. Untangle before
  either hostname moves, or a renewal will fail in a confusing way — see the
  bundled-SAN failure mode in the cert runbook.
