# Traefik LoadBalancer Source-IP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Traefik see the real client address (`192.168.1.100`) instead of a SNAT'd pod IP, so `forwardedHeaders.trustedIPs` can be narrowed to a `/32` and no pod can forge `X-Forwarded-For`.

**Architecture:** Install MetalLB in L2 mode and give the existing Traefik `LoadBalancer` Service a real IP (`192.168.1.110`), then set `externalTrafficPolicy: Local` so kube-proxy stops masquerading the source. nginx on LXC 100 moves from the NodePort to that IP. MetalLB announces the address only from nodes with a ready Traefik pod, which is what makes `Local` safe without pinning Traefik to named nodes.

**Tech Stack:** k3s v1.34.x, Traefik (k3s-bundled chart, configured via `HelmChartConfig`), MetalLB (Helm), nginx 1.18 on LXC 100, kube-vip (API VIP only).

**Spec:** `docs/superpowers/specs/2026-08-20-traefik-loadbalancer-source-ip-design.md`

## Global Constraints

- **This is live production infrastructure.** Every public service in the homelab rides this path. Any step that mutates the cluster runs in a maintenance window with the operator present.
- **Cluster mutations are classifier-gated for the agent.** Stage each mutating step as a script on the Proxmox master via tar-pipe, and have the operator run it with `! ssh root@192.168.1.52 "bash /tmp/<script>.sh"`. Never attempt the mutation directly.
- **All repo work happens in the worktree** `.git-worktrees/lb-source-ip` on branch `feat/traefik-loadbalancer-source-ip`. Always `git -C <abs-worktree>`. Never mutate the primary checkout.
- **nginx conf rollback is a live snapshot, never `git checkout`.** `scripts/proxy-check.sh` documents `proxy/sites/` as non-authoritative — certbot rewrites those files in place, and live filenames already drift from repo ones.
- **The IP is `192.168.1.110`.** It sits inside the documented static block `.48–.153`, so `docs/network-reservations.md` must record it.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`). No AI attribution in any commit, PR, or issue text.
- **Bash scripts** start with `set -Eeuo pipefail`, 2-space indent, `shellcheck`-clean.

## File Structure

| File | Responsibility |
|---|---|
| `k8s/metallb/values.yaml` | MetalLB Helm values (pinned chart version recorded here) |
| `k8s/metallb/ipaddresspool.yaml` | `IPAddressPool` + `L2Advertisement` for `192.168.1.110/32` |
| `k8s/kube-system/traefik-config.yaml` | **Modify** — the transitional and final `trustedIPs` values |
| `k8s/kube-system/traefik-pdb.yaml` | `PodDisruptionBudget` (`minAvailable: 1`) for Traefik |
| `k8s/kube-system/traefik-service-patch.yaml` | Documents the Service-level changes: `loadBalancerIP`, `externalTrafficPolicy`, pinned `nodePort`s, `allocateLoadBalancerNodePorts` |
| `proxy/sites/*.conf` (13 files) | **Modify** — `proxy_pass` targets move to `.110` |
| `docs/network-reservations.md` | **Modify** — record `.110` |
| `docs/runbooks/parley.md:102`, `docs/runbooks/twenty.md:77` | **Modify** — health-check commands off the NodePort |
| `CLAUDE.md` | **Modify** — traffic-flow section, and the missing wrk-5/wrk-6 rows |

---

### Task 1: MetalLB installed and holding the IP, routing nothing

**Files:**
- Create: `k8s/metallb/values.yaml`
- Create: `k8s/metallb/ipaddresspool.yaml`
- Test: live probe (below)

**Interfaces:**
- Consumes: nothing.
- Produces: `svc/traefik` in `kube-system` has `status.loadBalancer.ingress[0].ip == 192.168.1.110`, reachable on `:80`. Task 4 depends on this IP answering.

- [ ] **Step 1: Prove `.110` is unclaimed, right now**

```bash
ssh root@192.168.1.52 "ip neigh show 192.168.1.110; arping -D -I vmbr0 -c 3 192.168.1.110; echo exit=\$?"
```

Expected: no MAC in `ip neigh`, `arping -D` exits `0` (no duplicate found). **If anything answers, STOP** — pick another address and update the spec. The reservations doc is hand-maintained and has drifted before; this probe is the authority.

- [ ] **Step 2: Write the MetalLB values and pool manifests**

`k8s/metallb/values.yaml`:

```yaml
# MetalLB in L2 mode, providing the single ingress address for Traefik.
#
# strictARP is deliberately NOT set: it applies only to kube-proxy in IPVS mode,
# and k3s runs the embedded kube-proxy in iptables mode (no kube-proxy ConfigMap
# exists on this cluster).
#
# The speaker DaemonSet needs no tolerations for this design — Traefik runs on
# k3s-wrk-5/wrk-6, both untainted. If Traefik is ever moved onto a tainted node
# (the 3 control-plane servers, or wrk-4's nvidia.com/gpu), the speaker must get
# a matching toleration or MetalLB cannot announce from it.
speaker:
  logLevel: info
controller:
  logLevel: info
```

`k8s/metallb/ipaddresspool.yaml`:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ingress
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.110/32
  autoAssign: false  # only the Service that names this IP may claim it
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ingress
  namespace: metallb-system
spec:
  ipAddressPools:
    - ingress
```

- [ ] **Step 3: Stage the install script**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
tar -C "$WT/k8s/metallb" -cf - ipaddresspool.yaml values.yaml \
  | ssh root@192.168.1.52 'mkdir -p /tmp/metallb && tar -C /tmp/metallb -xf -'
ssh root@192.168.1.52 'cat > /tmp/metallb-install.sh' <<'SH'
set -Eeuo pipefail
helm repo add metallb https://metallb.github.io/metallb
helm repo update metallb
CHART_VERSION=$(helm search repo metallb/metallb -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["version"])')
echo "installing metallb chart ${CHART_VERSION}"
helm install metallb metallb/metallb -n metallb-system --create-namespace \
  --version "${CHART_VERSION}" -f /tmp/metallb/values.yaml --wait --timeout 5m
kubectl -n metallb-system rollout status ds/metallb-speaker --timeout=180s
kubectl apply -f /tmp/metallb/ipaddresspool.yaml
echo "CHART_VERSION=${CHART_VERSION}"
SH
```

- [ ] **Step 4: Operator runs it**

```
! ssh root@192.168.1.52 "bash /tmp/metallb-install.sh"
```

Expected: controller Deployment and speaker DaemonSet Ready; the script prints `CHART_VERSION=`. **Record that version into `k8s/metallb/values.yaml` as a comment** — the install must be reproducible.

- [ ] **Step 5: Claim the IP on the Traefik Service**

```bash
ssh root@192.168.1.52 'cat > /tmp/traefik-lbip.sh' <<'SH'
set -Eeuo pipefail
kubectl -n kube-system patch svc traefik --type merge -p \
  '{"metadata":{"annotations":{"metallb.io/address-pool":"ingress"}},"spec":{"loadBalancerIP":"192.168.1.110"}}'
kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/traefik-lbip.sh"`

- [ ] **Step 6: Probe — the IP serves, nothing routes to it yet**

```bash
ssh root@192.168.1.52 "curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: rancher.corbello.io' http://192.168.1.110"
```

Expected: `200` or `302` — the same status `https://rancher.corbello.io` returns today. A connection refused/timeout means MetalLB is not announcing; check `kubectl -n metallb-system logs ds/metallb-speaker | grep -i 192.168.1.110` before going further.

- [ ] **Step 7: Confirm public traffic is still completely unaffected**

```bash
for h in rancher argocd grafana harbor sonarqube; do
  printf '%-10s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 https://$h.corbello.io)"
done
```

Expected: identical to the pre-change baseline. Nothing points at `.110` yet, so any change here means MetalLB disturbed something — roll back with `helm uninstall metallb -n metallb-system`.

- [ ] **Step 8: Commit**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
git -C "$WT" add k8s/metallb/
git -C "$WT" commit -m "feat(metallb): L2 pool providing 192.168.1.110 for Traefik

Gives the existing Traefik LoadBalancer Service a real address so nginx can
reach it without the NodePort SNAT that forces trustedIPs wide open.

autoAssign is false so only the Service naming this IP can claim it."
```

---

### Task 2: Traefik survives an eviction before `Local` makes that fatal

**Files:**
- Create: `k8s/kube-system/traefik-pdb.yaml`
- Test: live probe (below)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `pdb/traefik` in `kube-system`, `minAvailable: 1`. Task 4 requires this to exist first.

Why this precedes the `etp` flip: with `Local`, MetalLB announces only from nodes with a ready Traefik pod. An eviction that zeroes ready endpoints on the announcing node takes the ingress IP with it.

- [ ] **Step 1: Write the PDB**

`k8s/kube-system/traefik-pdb.yaml`:

```yaml
# Traefik is the only ingress path for every K8s-hosted service, and with
# externalTrafficPolicy: Local the MetalLB speaker only announces 192.168.1.110
# from a node with a Ready Traefik pod. Losing both replicas at once therefore
# takes the ingress IP down, not just one backend.
#
# Pairs with the chart's maxSkew:1 hostname spread (see traefik-config.yaml).
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: traefik
  namespace: kube-system
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
```

- [ ] **Step 2: Verify the selector matches the live pods before applying**

```bash
ssh root@192.168.1.52 "kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik --no-headers | wc -l"
```

Expected: `2`. A `0` means the label is wrong and the PDB would protect nothing — fix the selector before continuing.

- [ ] **Step 3: Stage and apply**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
tar -C "$WT/k8s/kube-system" -cf - traefik-pdb.yaml | ssh root@192.168.1.52 'tar -C /tmp -xf -'
ssh root@192.168.1.52 'cat > /tmp/traefik-pdb.sh' <<'SH'
set -Eeuo pipefail
kubectl apply -f /tmp/traefik-pdb.yaml
kubectl -n kube-system get pdb traefik
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/traefik-pdb.sh"`

- [ ] **Step 4: Probe — the PDB reports real allowed disruptions**

```bash
ssh root@192.168.1.52 "kubectl -n kube-system get pdb traefik -o jsonpath='{.status.currentHealthy}/{.status.desiredHealthy} allowed={.status.disruptionsAllowed}{\"\n\"}'"
```

Expected: `2/1 allowed=1`. `allowed=0` with 2 healthy pods means the selector matched nothing useful — investigate before proceeding.

- [ ] **Step 5: Commit**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
git -C "$WT" add k8s/kube-system/traefik-pdb.yaml
git -C "$WT" commit -m "feat(traefik): PodDisruptionBudget before externalTrafficPolicy goes Local

With Local, the MetalLB speaker only announces the ingress IP from a node with
a Ready Traefik pod, so an eviction that zeroes ready endpoints takes public
ingress down rather than shifting it."
```

---

### Task 3: All 13 nginx vhosts move to the LoadBalancer IP

**Files:**
- Modify (live, on LXC 100): 13 confs in `/etc/nginx/sites-enabled/`
- Modify (repo): the matching files under `proxy/sites/`
- Test: live probe (below)

**Interfaces:**
- Consumes: `.110` answering on `:80` and `:443` (Task 1).
- Produces: zero references to `192.168.1.90:30278` or `192.168.1.91:3025[28]` in `sites-enabled`. Task 4 depends on this being complete — three of these vhosts are pinned to `.91`, which runs no Traefik pod, and would go dark the moment `etp` flips.

The 13 files:

```
argocd.corbello.io.conf          postiz.corbello.io.conf
crm.plotlens.ai.conf             rancher.corbello.io.conf
grafana.corbello.io.conf         sonarqube.corbello.io.conf
harbor.corbello.io.conf          temporal.corbello.io.conf
parley.corbello.io.conf          microsoft.plotlens.corbello.io.conf   <- .91
postiz-webhooks.corbello.io.conf plotlens.corbello.io.conf             <- .91
                                 website.plotlens.corbello.io.conf     <- .91
```

Mapping: `http://192.168.1.9X:30278` → `http://192.168.1.110:80`, `https://192.168.1.91:30252` → `https://192.168.1.110:443`.

- [ ] **Step 1: Capture the pre-change baseline for every affected hostname**

```bash
for h in rancher argocd grafana harbor sonarqube parley temporal postiz postiz-webhooks \
         plotlens website.plotlens microsoft.plotlens; do
  printf '%-22s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 https://$h.corbello.io)"
done
printf '%-22s %s\n' crm.plotlens.ai "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 https://crm.plotlens.ai)"
```

Save this output. It is the comparison for Step 5 — "it still works" is not checkable without it.

- [ ] **Step 2: Snapshot the live confs (this is the rollback)**

```bash
ssh root@192.168.1.52 'cat > /tmp/nginx-snapshot.sh' <<'SH'
set -Eeuo pipefail
STAMP=$(date +%Y%m%d-%H%M%S)
pct exec 100 -- bash -c "mkdir -p /root/nginx-backup-${STAMP} && \
  cp -L /etc/nginx/sites-enabled/*.conf /root/nginx-backup-${STAMP}/ && \
  ls /root/nginx-backup-${STAMP} | wc -l && echo /root/nginx-backup-${STAMP}"
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/nginx-snapshot.sh"`

Expected: a file count and the snapshot path. **Record that path** — it is the only rollback for this task. `cp -L` dereferences the symlinks so the snapshot holds real bytes.

- [ ] **Step 3: Rewrite the live confs**

```bash
ssh root@192.168.1.52 'cat > /tmp/nginx-repoint.sh' <<'SH'
set -Eeuo pipefail
pct exec 100 -- bash -c '
  set -Eeuo pipefail
  cd /etc/nginx/sites-enabled
  sed -i "s#http://192\.168\.1\.9[01]:30278#http://192.168.1.110:80#g; \
          s#https://192\.168\.1\.91:30252#https://192.168.1.110:443#g" *.conf
  echo "--- remaining NodePort references (want zero) ---"
  grep -RhoE "192\.168\.1\.9[01]:(30278|30252)" . | sort | uniq -c || echo none
  nginx -t
'
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/nginx-repoint.sh"`

Expected: `none`, then `nginx: configuration file /etc/nginx/nginx.conf test is successful`. **Do not reload if `nginx -t` fails** — restore from the Step 2 snapshot.

- [ ] **Step 4: Reload**

```bash
ssh root@192.168.1.52 'cat > /tmp/nginx-reload.sh' <<'SH'
set -Eeuo pipefail
pct exec 100 -- nginx -s reload
sleep 2
pct exec 100 -- systemctl is-active nginx
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/nginx-reload.sh"`

- [ ] **Step 5: Probe — every hostname matches its Step 1 baseline**

Re-run the Step 1 loop. Every status code must be identical. Any difference is a rollback trigger:

```bash
# rollback, using the recorded snapshot path
ssh root@192.168.1.52 "pct exec 100 -- bash -c 'cp /root/nginx-backup-<STAMP>/*.conf /etc/nginx/sites-enabled/ && nginx -t && nginx -s reload'"
```

- [ ] **Step 6: Confirm client IPs are still SNAT'd (nothing has changed yet)**

```bash
ssh root@192.168.1.52 "kubectl -n harbor logs deploy/harbor-registry --since=3m | grep -o 'remoteaddr=[0-9.]*' | sort | uniq -c | tail -3"
```

Expected: still `10.42.x.x`. `etp` is still `Cluster`, so this task must NOT have changed source-IP behavior. If real IPs appear here, something else changed and the plan's assumptions need re-checking.

- [ ] **Step 7: Mirror the change into the repo and commit**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
cd "$WT/proxy/sites"
sed -i 's#http://192\.168\.1\.9[01]:30278#http://192.168.1.110:80#g; \
        s#https://192\.168\.1\.91:30252#https://192.168.1.110:443#g' *.conf
grep -rhoE '192\.168\.1\.9[01]:(30278|30252)' . | sort | uniq -c || echo "none remaining"
git -C "$WT" add proxy/sites/
git -C "$WT" commit -m "feat(proxy): point every K8s vhost at the Traefik LoadBalancer IP

Moves 16 proxy_pass lines across 13 vhosts off the NodePort. Three of them
(plotlens, website.plotlens, microsoft.plotlens) were pinned to k3s-srv-1,
which runs no Traefik pod and would have gone dark when externalTrafficPolicy
becomes Local in the next step.

Note the repo copies are a mirror, not the source of truth: certbot rewrites
proxy/sites/ in place, so rollback is the live snapshot on LXC 100."
```

Note: the repo `sed` also touches `proxy/sites/plotlens.ai.conf`, a stale artifact with no live counterpart. Harmless; the spec lists deleting it as a follow-up.

---

### Task 4: SNAT stops, and the trust list narrows with no window

**Files:**
- Create: `k8s/kube-system/traefik-service-patch.yaml` (documentation of the live Service state)
- Modify: `k8s/kube-system/traefik-config.yaml`
- Test: live probe (below)

**Interfaces:**
- Consumes: Task 1's `.110`, Task 2's PDB, Task 3's repointed vhosts. **All three are hard prerequisites.**
- Produces: Traefik observing `192.168.1.100` as the peer; `trustedIPs` at `192.168.1.100/32`.

Ordering matters and is not arbitrary. Widening the trust list *first* means the `etp` flip is seamless: flipping `etp` while `trustedIPs` is `10.42.0.0/16` would leave Traefik seeing `.100` — a peer not in the list — so it would ignore `X-Forwarded-For` entirely and every request would collapse to one apparent client.

- [ ] **Step 1: Widen `trustedIPs` transitionally**

In `k8s/kube-system/traefik-config.yaml`, change both entryPoint lines to:

```yaml
      - "--entryPoints.web.forwardedHeaders.trustedIPs=10.42.0.0/16,192.168.1.100/32"
      - "--entryPoints.websecure.forwardedHeaders.trustedIPs=10.42.0.0/16,192.168.1.100/32"
```

Stage and apply:

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
tar -C "$WT/k8s/kube-system" -cf - traefik-config.yaml | ssh root@192.168.1.52 'tar -C /tmp -xf -'
ssh root@192.168.1.52 'cat > /tmp/traefik-trust-both.sh' <<'SH'
set -Eeuo pipefail
kubectl apply -f /tmp/traefik-config.yaml
sleep 20  # the k3s helm-controller reconciles asynchronously via a Job
kubectl -n kube-system rollout status deploy/traefik --timeout=180s
kubectl -n kube-system get deploy traefik -o yaml | grep trustedIPs
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/traefik-trust-both.sh"`

Expected: both lines show `10.42.0.0/16,192.168.1.100/32`. **The `sleep` is load-bearing** — `HelmChartConfig` changes are applied by a Job, so `rollout status` returns instantly against the old ReplicaSet if you check too early. If the args still show the old value, wait and re-check rather than re-applying.

- [ ] **Step 2: Confirm nothing broke on the widened list**

```bash
for h in rancher harbor plotlens; do
  printf '%-10s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 https://$h.corbello.io)"
done
```

Expected: matches the Task 3 Step 1 baseline.

- [ ] **Step 3: Flip `externalTrafficPolicy` to `Local`**

```bash
ssh root@192.168.1.52 'cat > /tmp/traefik-etp-local.sh' <<'SH'
set -Eeuo pipefail
kubectl -n kube-system patch svc traefik -p '{"spec":{"externalTrafficPolicy":"Local"}}'
sleep 5
kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy} {.status.loadBalancer.ingress[0].ip}{"\n"}'
curl -sS -o /dev/null -w 'via .110: %{http_code}\n' -H 'Host: rancher.corbello.io' http://192.168.1.110
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/traefik-etp-local.sh"`

Expected: `Local 192.168.1.110` and a `200`/`302`. Rollback if the curl fails:

```bash
ssh root@192.168.1.52 "kubectl -n kube-system patch svc traefik -p '{\"spec\":{\"externalTrafficPolicy\":\"Cluster\"}}'"
```

- [ ] **Step 4: Probe — the peer is now the proxy, not a pod**

```bash
ssh root@192.168.1.52 "curl -sS -o /dev/null -m 10 https://harbor.corbello.io/v2/; \
  kubectl -n harbor logs deploy/harbor-registry --since=2m | grep -o 'remoteaddr=[0-9.]*' | sort | uniq -c | tail -3"
```

Expected: `remoteaddr=192.168.1.100`. **This is the moment the whole change turns on.** Still `10.42.x.x` means SNAT is happening anyway — stop and diagnose; do not proceed to Step 5.

- [ ] **Step 5: Narrow `trustedIPs` to the `/32`**

Edit `k8s/kube-system/traefik-config.yaml` again, dropping the pod CIDR:

```yaml
      - "--entryPoints.web.forwardedHeaders.trustedIPs=192.168.1.100/32"
      - "--entryPoints.websecure.forwardedHeaders.trustedIPs=192.168.1.100/32"
```

Update the comment block above those lines: the `/32` is now correct *because* `etp` is `Local` and MetalLB delivers without SNAT. Re-stage and apply exactly as in Step 1.

- [ ] **Step 6: Probe — real client IPs, end to end**

From an external host (a laptop off-LAN, or any host that reaches the public name):

```bash
# find a tag that exists, rather than guessing one
TAG=$(curl -sS -u '<harbor-user>' \
  'https://harbor.corbello.io/api/v2.0/projects/plotlens/repositories/plotlens-api/artifacts?page_size=1' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["tags"][0]["name"])')
docker pull "harbor.corbello.io/plotlens/plotlens-api:${TAG}"
```

Then read what Harbor saw:

```bash
ssh root@192.168.1.52 "kubectl -n harbor logs deploy/harbor-registry --since=5m | grep -o 'remoteaddr=[0-9.]*' | sort | uniq -c | tail -5"
```

Expected: the puller's real WAN address. This is the pass condition for the entire change. During a maintenance window nothing else generates this traffic, so the pull is required, not optional.

- [ ] **Step 7: Negative test — forgery is refused**

```bash
ssh root@192.168.1.52 'cat > /tmp/xff-forge-test.sh' <<'SH'
set -Eeuo pipefail
kubectl run xff-forge-test --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Host: harbor.corbello.io' -H 'X-Forwarded-For: 1.2.3.4' \
  http://192.168.1.110/v2/
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/xff-forge-test.sh"`

Then:

```bash
ssh root@192.168.1.52 "kubectl -n harbor logs deploy/harbor-registry --since=2m | grep -c 'remoteaddr=1.2.3.4' || echo 0"
```

Expected: `0`. A non-zero count means the forgery was honored and the change did not achieve its purpose. Note the pod's source is a pod IP, not `.100`, which is exactly why the header must be ignored.

- [ ] **Step 8: Record the Service state in the repo and commit**

`k8s/kube-system/traefik-service-patch.yaml`:

```yaml
# The Traefik Service is created by the k3s-bundled chart, so these fields are
# applied as patches rather than owned by a manifest here. This file records the
# intended state so a rebuild does not silently lose it.
#
#   kubectl -n kube-system patch svc traefik --type merge -p "$(yq '.patch' this-file)"
#
# loadBalancerIP + the metallb.io/address-pool annotation claim 192.168.1.110
# from the 'ingress' pool (k8s/metallb/ipaddresspool.yaml).
#
# externalTrafficPolicy: Local is what stops kube-proxy masquerading the source,
# which is the entire point — it lets forwardedHeaders.trustedIPs be a /32.
# It is safe here only because MetalLB announces the IP solely from nodes with a
# Ready Traefik pod, and because a PDB keeps one alive (traefik-pdb.yaml).
patch:
  metadata:
    annotations:
      metallb.io/address-pool: ingress
  spec:
    loadBalancerIP: 192.168.1.110
    externalTrafficPolicy: Local
```

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
git -C "$WT" add k8s/kube-system/
git -C "$WT" commit -m "feat(traefik): externalTrafficPolicy Local and a /32 trust list

Removes the NodePort SNAT so Traefik observes 192.168.1.100 directly, which
makes forwardedHeaders.trustedIPs=192.168.1.100/32 both correct and
enforceable. A pod can no longer obtain a trusted source address by having its
own rewritten into the trust list.

The trust list was widened to 10.42.0.0/16,192.168.1.100/32 before the policy
flip and narrowed after, so there is no window in which Traefik ignores
X-Forwarded-For and every client collapses to one address."
```

---

### Task 5: Close the NodePort bypass without breaking rollback

**Files:**
- Modify: `k8s/kube-system/traefik-service-patch.yaml`
- Test: live probe (below)

**Interfaces:**
- Consumes: Task 4 complete and verified.
- Produces: no NodePorts on `svc/traefik`; `30278`/`30252` pinned in the recorded patch so re-enabling restores the same numbers.

- [ ] **Step 1: Prove nothing still targets the NodePorts**

```bash
ssh root@192.168.1.52 "pct exec 100 -- grep -RhoE '192\.168\.1\.9[01]:(30278|30252)' /etc/nginx/sites-enabled/ | sort | uniq -c || echo 'none in nginx'"
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
grep -rn '30278\|30252' "$WT/docs" "$WT/scripts" "$WT/k8s" 2>/dev/null | grep -v traefik-service-patch || echo "none in repo"
```

Expected: `none in nginx`, and in the repo only `docs/runbooks/parley.md:102` and `docs/runbooks/twenty.md:77` — fixed in Step 2. **If anything else appears, fix it before continuing.**

- [ ] **Step 2: Update the two runbook health-checks**

`docs/runbooks/parley.md:102` — replace the NodePort URL:

```bash
curl -sS -H 'Host: parley.corbello.io' http://192.168.1.110/readyz
```

`docs/runbooks/twenty.md:77`:

```bash
curl -H 'Host: crm.plotlens.ai' -I http://192.168.1.110/
```

- [ ] **Step 3: Pin the NodePorts, then remove them**

Pinning first is what makes rollback deterministic — 13 confs and 2 runbooks referenced these numbers, and Kubernetes does not promise to hand back the same ones on re-enable.

```bash
ssh root@192.168.1.52 'cat > /tmp/traefik-nodeports.sh' <<'SH'
set -Eeuo pipefail
echo "--- current ---"
kubectl -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}{.name}:{.port}/{.nodePort} {end}{"\n"}'
kubectl -n kube-system patch svc traefik --type merge -p \
  '{"spec":{"ports":[{"name":"web","port":80,"targetPort":"web","protocol":"TCP","nodePort":30278},
                     {"name":"websecure","port":443,"targetPort":"websecure","protocol":"TCP","nodePort":30252}]}}'
kubectl -n kube-system patch svc traefik --type merge -p '{"spec":{"allocateLoadBalancerNodePorts":false}}'
sleep 3
echo "--- after ---"
kubectl -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}{.name}:{.port}/{.nodePort} {end}{"\n"}'
curl -sS -o /dev/null -w 'via .110: %{http_code}\n' -H 'Host: rancher.corbello.io' http://192.168.1.110
SH
```

Operator: `! ssh root@192.168.1.52 "bash /tmp/traefik-nodeports.sh"`

Expected: the "after" line shows no `nodePort` values, and the curl still returns `200`/`302`. Rollback:

```bash
ssh root@192.168.1.52 "kubectl -n kube-system patch svc traefik --type merge -p '{\"spec\":{\"allocateLoadBalancerNodePorts\":true}}'"
```

- [ ] **Step 4: Probe — the bypass is gone, the service is not**

```bash
ssh root@192.168.1.52 "curl -sS -m 5 -o /dev/null -w 'nodeport: %{http_code}\n' -H 'Host: rancher.corbello.io' http://192.168.1.101:30278 || echo 'nodeport: refused (expected)'"
ssh root@192.168.1.52 "curl -sS -m 5 -o /dev/null -w 'lb ip:   %{http_code}\n' -H 'Host: rancher.corbello.io' http://192.168.1.110"
```

Expected: NodePort refused/timeout, `.110` still serving.

- [ ] **Step 5: Full public sweep against the Task 3 baseline**

Re-run the Task 3 Step 1 loop across all 13 hostnames. Every status must match. Then confirm the untouched LXC-backed vhosts are unaffected:

```bash
for h in n8n uptime keycloak; do
  printf '%-10s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 https://$h.corbello.io)"
done
```

- [ ] **Step 6: Verify both ACME paths still solve**

Two independent cert systems ride this path and a break here is silent for weeks — it
surfaces as an expiry, not an error. Check both.

cert-manager (K8s hostnames, HTTP-01 through Traefik):

```bash
ssh root@192.168.1.52 "kubectl get certificate -A -o wide --no-headers | awk '{print \$1, \$2, \$3, \$4}'; \
  kubectl get challenges -A --no-headers 2>/dev/null || echo 'no challenges in flight (expected)'"
```

Expected: every Certificate still `True`. A `False` with a stuck Challenge means the
solver Ingress can no longer be reached — roll back Task 5 Step 3 and diagnose.

certbot (LXC hostnames, HTTP-01 to nginx directly — should be untouched by this work):

```bash
ssh root@192.168.1.52 "pct exec 100 -- certbot renew --dry-run 2>&1 | tail -20"
```

Expected: `Congratulations, all simulated renewals succeeded`. Note this exercises every
lineage — a pre-existing failure on an unrelated domain is not caused by this change, but
do not wave it through: check it against the state before the maintenance window.

- [ ] **Step 7: Commit**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
git -C "$WT" add k8s/kube-system/traefik-service-patch.yaml docs/runbooks/parley.md docs/runbooks/twenty.md
git -C "$WT" commit -m "chore(traefik): drop the NodePorts now that nothing targets them

Pins nodePort 30278/30252 before disabling allocateLoadBalancerNodePorts so a
rollback deterministically restores the same numbers, and moves the two runbook
health-checks onto the LoadBalancer IP.

Closes LAN-external direct reachability only; any pod can still reach Traefik's
ClusterIP or pod IPs, which grants no XFF trust and is out of scope here."
```

---

### Task 6: Documentation matches reality

**Files:**
- Modify: `docs/network-reservations.md`, `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-08-20-traefik-loadbalancer-source-ip-design.md` (status line)
- Test: `scripts/proxy-check.sh`

**Interfaces:**
- Consumes: Tasks 1–5 complete.
- Produces: nothing downstream. This is the task that stops the next person rediscovering all of it.

- [ ] **Step 1: Reserve `.110`**

In `docs/network-reservations.md`, add `192.168.1.110` to the host table as the **Traefik ingress VIP (MetalLB L2)**, noting it has no fixed MAC — it is announced by whichever node currently runs a Traefik pod — so like `.90` it cannot be a normal DHCP reservation and must stay outside the pool.

- [ ] **Step 2: Correct the traffic-flow section in `CLAUDE.md`**

Replace the K8s half of the flow diagram:

```
Internet → corbello.ddns.net → PCT 100 "proxy" (NGINX + certbot TLS)
                                 ├─ K3s services → 192.168.1.110 (Traefik, MetalLB L2)
                                 └─ LXC services → direct to the guest
```

And correct the sentence claiming "K3s services are reached via Traefik on the API VIP" — they are reached on the ingress VIP `.110`; `.90` is the kube-API VIP only.

- [ ] **Step 3: Add the two missing worker rows**

`CLAUDE.md`'s K3s section lists k3s-wrk-1..4 but the cluster has 9 nodes. Add k3s-wrk-5 (`.101`) and k3s-wrk-6 (`.102`), both untainted, and note that Traefik currently runs on them — which is what makes MetalLB's announcement work.

- [ ] **Step 4: Flip the spec's status line**

```markdown
**Status:** implemented 2026-08-20
```

- [ ] **Step 5: Run the repo's own drift check**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
cd "$WT" && bash scripts/proxy-check.sh
```

Expected: passes. `proxy/sites/` differences are reported for awareness but never fail — the check only enforces `proxy/conf.d/`.

- [ ] **Step 6: Commit and open the PR**

```bash
WT=/home/jacorbello/repos/cortech-infra/.git-worktrees/lb-source-ip
git -C "$WT" add -A
git -C "$WT" commit -m "docs: record the ingress VIP and correct the traffic-flow diagram

192.168.1.110 is now the Traefik ingress VIP (MetalLB L2, no fixed MAC), and
K3s services no longer route via the kube-API VIP. Adds the k3s-wrk-5/wrk-6
rows the worker table was missing."
git -C "$WT" push -u origin feat/traefik-loadbalancer-source-ip
```

PR body must include: the linked issue (`Closes #76`, unbacticked so the link fires), the risk/rollback per task, and the before/after `remoteaddr` evidence from Task 4 Step 6.

---

## Follow-ups (file as issues, do not do here)

- PSA `baseline`/`restricted` across namespaces plus strict `rp_filter`. The spec's residual-risk section explains why this matters more than it first appears: `argocd-application-controller` holds wildcard RBAC, so creating a spoofing-capable pod needs only merge rights on a GitOps-synced repo.
- Router-forward migration retiring nginx from the K8s path.
- `infisical.corbello.io.conf` pinned to a single node's NodePort (`.91:30880`).
- Delete `proxy/sites/plotlens.ai.conf` (stale, no live counterpart).
