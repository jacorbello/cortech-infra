#!/usr/bin/env bash
# Build two new core-app K3s workers on the R640 (cortech-node3).
#
# WHY: the core-app pool is out of memory — k3s-wrk-1 is at 91% of memory
# requests and k3s-wrk-2 at 97%, both on 8 GiB VMs, while node3 sits at 21%
# with 327 GiB free. Nothing is Pending yet; the next deployment onto core-app
# would be. These also give the pool a third fault domain, so a spread survives
# losing `cortech` (which hosts the proxy, Postgres and Keycloak as well as
# k3s-wrk-2).
#
#   k3s-wrk-5  VM 209  192.168.1.101  8 vCPU / 32 GiB
#   k3s-wrk-6  VM 210  192.168.1.102  8 vCPU / 32 GiB
#
# Both labelled role=core-app, node-type=worker. Untainted.
#
# Modelled on k3s-wrk-4 (VM 207), not on the template: the template lacks
# `cpu: host`, and a cloned VM left on the default kvm64 has no x86-64-v2, which
# crash-loops numpy/ML workloads in a way that looks like an app bug.
#
# Run ON the Proxmox master. Safe to re-run: it refuses if a VMID already exists.
set -Eeuo pipefail

NODE=cortech-node3
TEMPLATE=9001
STORAGE=storage-pool
K3S_VERSION=v1.34.3+k3s1     # match the control plane, not wrk-4's 1.34.5
VIP=192.168.1.90
GW=192.168.1.1
DISK=100G
NODE3_IP=192.168.1.114

# qm only manages VMs on the node that owns them, and both the template and the
# new VMs live on node3 — so every qm call runs there, over ssh. kubectl stays
# here on the master.
on3() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE3_IP}" "$@"; }

build() {
  local VMID=$1 NAME=$2 IP=$3

  echo
  echo "############ $NAME (VM $VMID, $IP) ############"

  if on3 "qm status $VMID" >/dev/null 2>&1; then
    echo "  VMID $VMID already exists — refusing to touch it. Skipping."
    return 0
  fi

  echo "== clone from template $TEMPLATE =="
  on3 "qm clone $TEMPLATE $VMID --name $NAME --full 1 --storage $STORAGE"

  echo "== size, cpu type, cloud-init =="
  # cpu host is load-bearing: the default kvm64 lacks x86-64-v2.
  on3 "qm set $VMID --cores 8 --memory 32768 --cpu host --agent enabled=1 \
       --onboot 1 --ciuser k3s --ipconfig0 ip=${IP}/24,gw=${GW} \
       --sshkeys /root/.ssh/authorized_keys"

  on3 "qm disk resize $VMID scsi0 $DISK" || echo "  (disk already >= $DISK)"

  echo "== MAC (record this in docs/network-reservations.md) =="
  on3 "qm config $VMID" | grep -E '^net0:'

  echo "== start =="
  on3 "qm start $VMID"

  echo "== waiting for ssh on $IP (up to 3 min) =="
  for i in $(seq 1 36); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=4 "k3s@${IP}" true 2>/dev/null; then
      echo "  up after $((i*5))s"; break
    fi
    [ "$i" = 36 ] && { echo "  FAILED: no ssh on $IP" >&2; return 1; }
    sleep 5
  done

  echo "== install k3s agent $K3S_VERSION =="
  ssh -o StrictHostKeyChecking=no "k3s@${IP}" \
    "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='${K3S_VERSION}' \
       K3S_URL='https://${VIP}:6443' K3S_TOKEN='${TOKEN}' sh -"

  echo "== waiting for the node to register =="
  for i in $(seq 1 24); do
    if kubectl get node "$NAME" >/dev/null 2>&1; then echo "  registered"; break; fi
    [ "$i" = 24 ] && { echo "  FAILED: $NAME never registered" >&2; return 1; }
    sleep 5
  done
  kubectl wait --for=condition=Ready "node/$NAME" --timeout=180s

  echo "== label =="
  kubectl label node "$NAME" role=core-app node-type=worker --overwrite
}

echo "== join token from k3s-srv-1 =="
# The k3s VMs refuse root logins ("Please login as the user \"k3s\"") — the
# cloud image's default user is k3s, with sudo.
TOKEN=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes k3s@192.168.1.91 \
  "sudo cat /var/lib/rancher/k3s/server/node-token")
[ -n "$TOKEN" ] || { echo "FATAL: could not read the join token" >&2; exit 1; }
echo "  got it (${#TOKEN} chars, not printed)"

echo
echo "== capacity check before we start =="
FREE=$(pvesh get "/nodes/${NODE}/status" --output-format json | python3 -c "
import json,sys; print(int(json.load(sys.stdin)['memory']['free']/2**30))")
echo "  ${NODE}: ${FREE} GiB free, need 64 GiB for the pair"
[ "$FREE" -gt 80 ] || { echo "FATAL: not enough free memory on ${NODE}" >&2; exit 1; }

build 209 k3s-wrk-5 192.168.1.101
build 210 k3s-wrk-6 192.168.1.102

echo
echo "################ result ################"
kubectl get nodes -L role -o wide
echo
echo "=== core-app pool memory pressure, after ==="
for n in k3s-wrk-1 k3s-wrk-2 k3s-wrk-5 k3s-wrk-6; do
  kubectl describe node "$n" 2>/dev/null \
    | awk '/Allocated resources/,/Events/' | grep -E '^  memory' | sed "s/^/  $n /"
done

echo
echo "NEXT:"
echo "  1. Record both MACs above in docs/network-reservations.md (.101, .102)."
echo "  2. Update CLAUDE.md's cluster table with VM 209/210."
echo "  3. Optional: kubectl -n parley rollout restart deploy/parley to spread"
echo "     across the wider pool — with 4 core-app nodes the soft constraint has"
echo "     more room, though it is still ScheduleAnyway and not guaranteed."
