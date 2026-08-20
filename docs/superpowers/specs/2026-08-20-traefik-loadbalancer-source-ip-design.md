# Give Traefik a LoadBalancer IP so it sees the real client address

**Issue:** [#76](https://github.com/jacorbello/cortech-infra/issues/76)
**Status:** design approved, not yet implemented
**Date:** 2026-08-20

## Problem

nginx on LXC 100 (`192.168.1.100`) reaches Traefik through a NodePort. The Traefik
Service is `externalTrafficPolicy: Cluster`, so kube-proxy SNATs the source before
Traefik sees it — harbor-registry logs the peer as `10.42.3.0`, never as the proxy.

That forced `forwardedHeaders.trustedIPs` to `10.42.0.0/16` in
[#75](https://github.com/jacorbello/cortech-infra/pull/75), which means **any pod can
forge `X-Forwarded-For`** and have every backend believe it. It also costs client-IP
integrity in the logs of Harbor, Rancher, ArgoCD, SonarQube, Infisical and Grafana.

The narrower `192.168.1.100/32` is not an option: it matches nothing, because the SNAT
happens before the check. Setting it is what broke every Harbor push for a day
(`Family-Friendly-Inc/plotlens#6988`).

The fix is to remove the SNAT, not to tune the trust list.

## Approach

Give Traefik a real LoadBalancer IP via MetalLB in L2 mode, set
`externalTrafficPolicy: Local`, and point nginx at that IP. MetalLB announces the address
only from nodes with a ready Traefik pod, so `Local` cannot black-hole traffic the way a
hand-pinned node would — the component solves the placement problem instead of us.
Traefik then sees `192.168.1.100` literally, and `trustedIPs=192.168.1.100/32` becomes
correct and enforceable.

### Why not the alternatives

- **PROXY protocol** — inherits the same defect. `proxyProtocol.trustedIPs` would still
  have to trust `10.42.0.0/16` because of the same SNAT, so a pod could dial the NodePort
  and speak a forged PROXY header. It moves forgery from L7 to L4.
- **`etp: Local` with Traefik pinned to named nodes** — works, but re-implements by hand
  what MetalLB does automatically, and couples nginx to specific node IPs.
- **Retiring nginx from the K8s path entirely** (router forwards 80/443 straight at the
  ingress VIP) — the textbook end state, and now known to be feasible since
  `ClusterIssuer/letsencrypt-prod` already solves HTTP-01 through Traefik. Deliberately
  out of scope: it needs a router change, a cert cutover for ~13 LXC-backed hostnames,
  and a real maintenance window. Filed separately.

## Preconditions (verified 2026-08-20)

| Fact | Evidence |
|---|---|
| Traefik Service is already `type: LoadBalancer`, no external IP | `status.loadBalancer: {}` |
| k3s servicelb is off, so nothing contends for the IP | `--disable servicelb` in the k3s unit |
| kube-vip will not fight MetalLB | `svc_enable=false`, `cp_enable=true`, `address=192.168.1.90` |
| `192.168.1.110` is unassigned | `arp -n` incomplete, absent from all `pct`/`qm` guest configs and from `network-reservations.md` |
| Traefik runs on k3s-wrk-5 / k3s-wrk-6 | neither is `.91` — see scope below |
| Service exposes 80→30278, 443→30252 | `kubectl get svc -n kube-system traefik` |

`.110` sits inside the documented static block (`.48–.153`), so it must be added to
`network-reservations.md` as part of this work.

## Scope — 16 lines across 13 files

This is the part that makes the change dangerous, and the original draft got it wrong.

| Target | Files | Note |
|---|---|---|
| `192.168.1.90:30278` | 10 | argocd, crm.plotlens.ai, grafana, harbor, parley, postiz, postiz-webhooks, rancher, sonarqube, temporal |
| `192.168.1.91:30278` **and** `:30252` | 3 | plotlens, website.plotlens, microsoft.plotlens — **pinned to k3s-srv-1** |

k3s-srv-1 runs no Traefik pod. If `etp: Local` lands while those three still point at
`.91`, all three vhosts go dark. **All 13 must move before the `etp` flip.**

Mapping: `:30278` → `http://192.168.1.110:80`, `:30252` → `https://192.168.1.110:443`.
The `https` upstreams set `proxy_ssl_verify off`, so there is no SAN or SNI concern.

Explicitly out of scope, confirmed unaffected:

- `infisical.corbello.io.conf` → `.91:30880` is `infisical/infisical-nodeport`, a
  different Service. Same single-node fragility; its own cleanup.
- `sites-available/osint.corbello.io.conf` hardcodes `:30278` but is not enabled.
- `proxy/sites/plotlens.ai.conf` is a stale repo artifact with no live counterpart.

## Cutover

Each step is verifiable and reversible on its own.

0. **Prove `.110` is unclaimed at apply time** — `ip neigh show 192.168.1.110` and
   `arping -D -I vmbr0 192.168.1.110` from the Proxmox master. The reservations doc is
   hand-maintained and has drifted before; do not trust it alone.
1. **Install MetalLB.** Not present today (`helm list -A` shows no release, no
   `metallb-system` namespace), so this is a fresh install:
   ```bash
   helm repo add metallb https://metallb.github.io/metallb
   helm install metallb metallb/metallb -n metallb-system --create-namespace \
     --version <pin at install time>
   ```
   Then apply an `IPAddressPool` (`192.168.1.110/32`) and an `L2Advertisement`, both in
   `metallb-system`. Traefik picks up the IP; nothing routes there yet.
   Verify: `curl -H 'Host: rancher.corbello.io' http://192.168.1.110`.

   Two placement facts, both checked: `strictARP` is **not** required here — it applies
   only to kube-proxy in IPVS mode, and k3s runs the embedded kube-proxy in iptables mode
   (no `kube-proxy` ConfigMap exists). And the speaker DaemonSet needs no tolerations for
   this design: wrk-5 and wrk-6 are untainted. If Traefik is ever moved onto a tainted
   node (the 3 control-plane servers, or wrk-4's `nvidia.com/gpu`), the speaker must be
   given a matching toleration or MetalLB cannot announce from it.
2. **Add a PodDisruptionBudget** (`minAvailable: 1`) for `kube-system/traefik`, pairing
   with the existing `maxSkew: 1` hostname spread. Must precede the `etp` flip: with
   `Local`, an eviction that zeroes ready endpoints on the announcing node takes the VIP
   with it.
3. **Snapshot the 13 live confs on LXC 100** into a dated directory, then repoint all 16
   lines and reload. Still `etp: Cluster`, so this is a pure address change.
   **Rollback is the snapshot, not `git checkout`** — `scripts/proxy-check.sh` documents
   `proxy/sites/` as non-authoritative because certbot rewrites those files in place, and
   live filenames already drift from repo ones.
4. **Widen the trust list transitionally to `10.42.0.0/16,192.168.1.100/32`.** This step
   exists purely to remove a window. Flipping `etp` first would leave Traefik seeing
   `.100` — a peer *not* in the current `10.42.0.0/16` list — so it would ignore
   `X-Forwarded-For` entirely and every request would collapse to one apparent client
   until step 6 landed. Trusting both the old and new peer means the flip is seamless.
5. **Set `externalTrafficPolicy: Local`.** This is where SNAT stops. Rollback: patch back
   to `Cluster`, ~10s.
6. **Narrow `trustedIPs` to `192.168.1.100/32`.** This is the step that actually closes
   the SNAT-forgery path.
7. **Pin the NodePorts, then remove them.** Set `spec.ports[].nodePort` explicitly to
   30278/30252 *before* setting `allocateLoadBalancerNodePorts: false`, so that re-enabling
   the field during a rollback deterministically restores the same numbers — 13 nginx
   confs and 2 runbooks reference them. Do this only after confirming nothing still
   targets them, including `docs/runbooks/parley.md:102` and `docs/runbooks/twenty.md:77`,
   whose health-check commands must be updated to `.110` in this same PR.

## Verification

- `curl -sI` across all 13 migrated hostnames plus 3 untouched LXC hostnames, before and
  after. All must return their pre-change status.
- **Generate the traffic, don't wait for it.** During a maintenance window nothing else
  will hit Harbor, so after step 6 (the `/32` narrowing) run a pull from an external host —
  `docker pull harbor.corbello.io/plotlens/plotlens-api:<tag>` — then
  `kubectl -n harbor logs deploy/harbor-registry --since=5m | grep remoteaddr`.
  A real WAN address while `trustedIPs` is `/32` is the pass condition for the whole
  change; today that combination logs `10.42.3.x`.
- **Negative test, valid only after step 6.** From a scratch pod, send
  `X-Forwarded-For: 1.2.3.4` with `Host: harbor.corbello.io` to `.110` and confirm
  harbor-registry's `remoteaddr` does not show `1.2.3.4`. Run before step 6 it will
  "fail" by design, because the trust list is still wide. Creating the pod is a mutation
  — it belongs in the controlled window.
- Confirm both ACME paths still work: certbot on LXC 100 for LXC hostnames, cert-manager
  HTTP-01 through Traefik for K8s hostnames.

## What this does and does not claim

**Closes:** the SNAT forgery path. A pod can no longer obtain a trusted source address by
having its own rewritten into the trust list.

**Does not close:** raw source-IP spoofing. No Pod Security Admission is enforced on any
of the 44 namespaces, so `hostNetwork` and `NET_RAW` are unrestricted, and reverse-path
filtering is largely absent — `rp_filter=0` (none) on **6 of 9 nodes** (srv-1, srv-2,
srv-3, wrk-1, wrk-2, wrk-3) and `2` (loose) only on wrk-4, wrk-5 and wrk-6. A pod that can
be created with those capabilities can emit a packet claiming `src=192.168.1.100`.

Two things bound that attack, and one does not bound it as much as it first appears.

Over TCP, a blind-spoofed source cannot complete a handshake — the SYN-ACK goes to the
real `.100` — so the attacker needs to be on-path, not merely able to emit a packet.

Who can create such a pod is the weaker bound. CI runners cannot: `kubectl auth can-i
create pods` is `no` for all six `arc-runners` service accounts (including `default` and
`moltbot-deployer`), and that namespace holds no kubeconfig secret. But
`argocd-application-controller` is bound to a ClusterRole granting
`apiGroups:['*'] resources:['*'] verbs:['*']`, and `rancher` and `rancher-webhook` are
bound to `cluster-admin`. With no PSA on any namespace, **anyone who can merge to a
GitOps-synced repo, or who holds Rancher access, can create a `hostNetwork`/`NET_RAW` pod
without compromising anything else.** That is a materially lower bar than "the cluster is
already compromised," and it is why the PSA follow-up is listed rather than deferred
indefinitely.

This is the floor of IP-based trust on a flat L2 — it is not made worse by this change —
but "forgery closed" is the wrong phrase and is not used here.

**Accepted:** MetalLB L2 means any host on VLAN 1 can ARP-claim `.110`. This is the same
exposure `.90` already carries. Documented, not redesigned.

**Not addressed:** any pod can still reach Traefik's ClusterIP or pod IPs directly on
`:8000`/`:8443`, bypassing nginx. Step 7 closes LAN-external NodePort reachability only.
That intra-cluster path grants no XFF trust (the source is the pod's own `10.42.x.x`), so
it does not undermine this design, but the "bypass closed" framing would overstate it.

## Follow-ups

- PSA `baseline`/`restricted` plus strict `rp_filter` across nodes.
- Router-forward migration retiring nginx from the K8s path.
- `CLAUDE.md` worker table omits k3s-wrk-5 and k3s-wrk-6.
- `infisical.corbello.io.conf` pinned to a single node's NodePort.
- `proxy/sites/plotlens.ai.conf` stale artifact.

## Review

Design reviewed by review-mesh over three rounds (claims / security / outage); the
round-by-round findings are recorded in the issue #76 thread rather than asserted here, so
they are checkable. Data-loss and false-green mandates were not dispatched in any round —
no migration or SQL, no test or CI step. Two claims raised by reviewers were checked and
did not hold as stated: CI runners cannot create pods (round 2), and `strictARP` is not
required under k3s's iptables kube-proxy (round 3).
