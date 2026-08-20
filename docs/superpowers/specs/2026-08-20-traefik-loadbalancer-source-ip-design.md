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
1. **Install MetalLB** (L2), `IPAddressPool` = `192.168.1.110/32`, `L2Advertisement`.
   Traefik picks up the IP. Nothing routes there yet.
   Verify: `curl -H 'Host: rancher.corbello.io' http://192.168.1.110`.
2. **Add a PodDisruptionBudget** (`minAvailable: 1`) for `kube-system/traefik`, pairing
   with the existing `maxSkew: 1` hostname spread. Must precede the `etp` flip: with
   `Local`, an eviction that zeroes ready endpoints on the announcing node takes the VIP
   with it.
3. **Snapshot the 13 live confs on LXC 100** into a dated directory, then repoint all 16
   lines and reload. Still `etp: Cluster`, so this is a pure address change.
   **Rollback is the snapshot, not `git checkout`** — `scripts/proxy-check.sh` documents
   `proxy/sites/` as non-authoritative because certbot rewrites those files in place, and
   live filenames already drift from repo ones.
4. **Set `externalTrafficPolicy: Local`.** This is where SNAT stops. Rollback: patch back
   to `Cluster`, ~10s.
5. **Set `trustedIPs=192.168.1.100/32`.** This is the step that actually closes the
   SNAT-forgery path.
6. **Set `allocateLoadBalancerNodePorts: false`**, after confirming nothing still targets
   30278/30252 — including `docs/runbooks/parley.md:102` and `docs/runbooks/twenty.md:77`,
   whose health-check commands must be updated to `.110` in this same PR.

## Verification

- `curl -sI` across all 13 migrated hostnames plus 3 untouched LXC hostnames, before and
  after. All must return their pre-change status.
- harbor-registry logs a real WAN address while `trustedIPs` is `/32` — today that
  combination logs `10.42.3.x`. This is the pass condition for the whole change.
- **Negative test, valid only after step 5.** From a scratch pod, send
  `X-Forwarded-For: 1.2.3.4` with `Host: harbor.corbello.io` to `.110` and confirm
  harbor-registry's `remoteaddr` does not show `1.2.3.4`. Run before step 5 it will
  "fail" by design, because the trust list is still wide. Creating the pod is a mutation
  — it belongs in the controlled window.
- Confirm both ACME paths still work: certbot on LXC 100 for LXC hostnames, cert-manager
  HTTP-01 through Traefik for K8s hostnames.

## What this does and does not claim

**Closes:** the SNAT forgery path. A pod can no longer obtain a trusted source address by
having its own rewritten into the trust list.

**Does not close:** raw source-IP spoofing. No Pod Security Admission is enforced on any
of the 44 namespaces, so `hostNetwork` and `NET_RAW` are unrestricted, and reverse-path
filtering is inconsistent — `rp_filter=2` (loose) on wrk-5/wrk-6, but `0` (none) on
srv-1, srv-2 and wrk-1. A pod that can be created with those capabilities can emit a
packet claiming `src=192.168.1.100`.

The practical cost of that attack is high: over TCP a blind-spoofed source cannot complete
a handshake, and no service account that could create such a pod exists today —
`kubectl auth can-i create pods` is `no` for all five `arc-runners` service accounts,
including `moltbot-deployer`, and there is no kubeconfig secret in that namespace. So the
attacker must already hold create-pod rights, which means the cluster is already
compromised. This is the floor of IP-based trust on a flat L2, not a regression — but
"forgery closed" is the wrong phrase and is not used here.

**Accepted:** MetalLB L2 means any host on VLAN 1 can ARP-claim `.110`. This is the same
exposure `.90` already carries. Documented, not redesigned.

**Not addressed:** any pod can still reach Traefik's ClusterIP or pod IPs directly on
`:8000`/`:8443`, bypassing nginx. Step 6 closes LAN-external NodePort reachability only.
That intra-cluster path grants no XFF trust (the source is the pod's own `10.42.x.x`), so
it does not undermine this design, but the "bypass closed" framing would overstate it.

## Follow-ups

- PSA `baseline`/`restricted` plus strict `rp_filter` across nodes.
- Router-forward migration retiring nginx from the K8s path.
- `CLAUDE.md` worker table omits k3s-wrk-5 and k3s-wrk-6.
- `infisical.corbello.io.conf` pinned to a single node's NodePort.
- `proxy/sites/plotlens.ai.conf` stale artifact.

## Review

Design reviewed by review-mesh over two rounds (claims / security / outage). Round 1
blocked on the `.91` pinning and the missing PDB; round 2 returned WARN with no blockers.
Data-loss and false-green mandates were not dispatched — no migration or SQL, no test or
CI step. The CI-escalation claim raised in round 2 was checked and did not hold.
