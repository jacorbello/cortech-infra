# Parley runbook

Planning poker and standups at <https://parley.corbello.io>. One Go binary with the
frontend compiled in, plus Postgres — no second service, no Node runtime.

| | |
|---|---|
| Namespace | `parley` |
| Chart | `ghcr.io/lets-parley/charts` chart `parley`, pinned in `apps/parley/argocd-application.yaml` |
| Values | `apps/parley/values.yaml` |
| Extras | `apps/parley/extras/` — namespace, InfisicalSecret, NetworkPolicy, IngressRoute |
| Ingress | nginx LXC 100 (`proxy/sites/parley.corbello.io.conf`) → Traefik → Service |
| Database | shared Postgres LXC 114 (`192.168.1.83`), database `parley` |
| Auth | OIDC, Keycloak realm `parley`, confidential client `parley` |
| Secrets | Infisical homelab project, env `dev`, path `/parley` → K8s secret `parley` |

## Upgrading

Bump `targetRevision` in `apps/parley/argocd-application.yaml`, merge, and re-apply the
Application by hand — Application CRs are not self-managed in this cluster.

**Roll forward, never back.** Parley refuses to start on an image older than the
migrations already applied to its database. That is by design and protects the schema; the
recovery for a bad release is a newer image, not an older one.

## Things that will bite

### The nginx vhost overwrites X-Forwarded-For on purpose

`proxy/sites/parley.corbello.io.conf` sets:

```nginx
proxy_set_header X-Forwarded-For $remote_addr;
```

Every other site in `proxy/sites/` uses `$proxy_add_x_forwarded_for` (append). Do not
"fix" this one to match. Parley checks the immediate socket peer against
`trustedProxyCIDRs`, then walks the XFF chain **right-to-left** to the first untrusted
entry — so an appended, caller-supplied value would be read as the client address and hand
anyone a free room-code brute-force bypass.

Verify (note `-R`, not `-r` — sites-enabled entries are symlinks):

```bash
ssh root@192.168.1.52 "pct exec 100 -- grep -R 'X-Forwarded-For' \
  /etc/nginx/sites-enabled/parley.corbello.io.conf"
```

### The NetworkPolicy is load-bearing, not decorative

`trustedProxyCIDRs` includes the whole pod CIDR, because the peer is always a Traefik pod
and those IPs are dynamic. On its own that would let *any* pod in the cluster forge a
client address. `apps/parley/extras/networkpolicy.yaml` restricts ingress to Traefik, and
Traefik's own `forwardedHeaders.trustedIPs` was narrowed to `192.168.1.100/32` so the same
forgery can't be staged one hop upstream. Removing either one silently reopens the hole.

The selector must stay `kubernetes.io/metadata.name: kube-system` — that is the only
matchable label on that namespace, and a wrong selector fails **closed**, taking Parley
offline.

### There is no access log

Parley emits no per-request or per-connection logging at any level, by design. Any
troubleshooting step of the form "grep the logs for X" will produce silence — which reads
as a passing check. Use behavioral tests instead.

### `/readyz` does not check OIDC

It pings the DB pool and the fanout listener. Discovery is deferred to first sign-in, so a
wrong issuer, client ID, or client secret leaves readiness green. Only a real browser
sign-in exercises the identity path.

## Common tasks

```bash
# health
ssh root@192.168.1.52 "kubectl -n parley get pods -o wide; kubectl -n parley get pdb"

# is it the app or the ingress?  (in-cluster, via Traefik)
ssh root@192.168.1.52 "curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: parley.corbello.io' http://192.168.1.90:30278/readyz"

# boot settings — cookie_secure, auth_mode, allowed_ws_origin
ssh root@192.168.1.52 "kubectl -n parley logs -l app.kubernetes.io/name=parley \
  --tail=50 | grep 'boot settings'"

# rotate the DB password / OIDC client secret
#   update Infisical at /parley; the operator resyncs within 60s, then:
ssh root@192.168.1.52 "kubectl -n parley rollout restart deploy/parley"
```

## Verifying cross-replica realtime

Presence, session fanout and the passcode throttle live in Postgres (v0.4.1+), so replicas
share state via `LISTEN/NOTIFY`. To prove it actually works across pods:

A browser pointed at `kubectl port-forward` **cannot** do this — `cookie_secure` is true,
so the session cookie is never sent over `http://localhost`, and `rejectCrossSite` refuses
a localhost origin. The page looks dead and reads as "fanout is broken."

Instead, copy a `parley_session` cookie from a real authenticated browser session,
port-forward each pod to its own local port, and connect a raw client to both:

```bash
websocat -H 'Origin: https://parley.corbello.io' \
         -H 'Cookie: parley_session=<value>' \
         'ws://127.0.0.1:18081/ws?session=<id>'
```

Drive a vote/reveal and confirm both sockets receive it.

## Checking the NetworkPolicy is enforced

k3s denies with iptables **DROP**, so a blocked connection hangs. A timeout is the pass;
"connection refused" or a 200 means the policy is not working. Always cap the wait:

```bash
kubectl run netpol-probe -n plotlens --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sv --max-time 5 http://parley.parley.svc.cluster.local
```

## Backups

The `parley` database is in `scripts/pg-backup.sh` `DEFAULT_DBS`, dumped daily to the node3
NFS share. Note that is a single on-cluster copy verified only by `gzip -t` and a
`CREATE TABLE` count — it is not a tested restore. The whole-instance
`pg_basebackup` + WAL on LXC 114 is the other layer, but restoring it rolls back every
co-tenant database to the same timestamp.
