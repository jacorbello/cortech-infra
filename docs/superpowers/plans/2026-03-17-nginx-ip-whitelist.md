# NGINX IP Whitelist Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable NGINX `geo`-based IP whitelist to the reverse proxy (LXC 100) with GitHub Actions `workflow_dispatch` for operator-managed add/remove.

**Architecture:** Per-service `geo` variables in `proxy/conf.d/whitelist.conf` drive a `$allowed_<service>` check in each protected server block. Whitelist IP files are git-managed and rsync'd to LXC 100 by a self-hosted ARC runner via SSH.

**Tech Stack:** NGINX 1.18.0 (Ubuntu, LXC 100), Kubernetes ARC runner (actions.summerwind.dev/v1alpha1), GitHub Actions workflow_dispatch, rsync over SSH, K8s Secrets.

---

## File Map

| Action | Path | Purpose |
|--------|------|---------|
| Create | `proxy/conf.d/whitelist.conf` | `geo` variable definitions — one block per protected service |
| Create | `proxy/conf.d/whitelist-global.conf` | IPs allowed on all protected services |
| Create | `proxy/conf.d/whitelist-osint-ips.conf` | IPs allowed only on `osint.corbello.io` |
| Modify | `proxy/sites/osint.corbello.io.conf` | Add `if ($allowed_osint = 0) { return 444; }` guard |
| Create | `k8s/actions-runner-system/cortech-infra-runner.yaml` | ARC RunnerDeployment for this repo |
| Create | `.github/workflows/add-ip-whitelist.yml` | workflow_dispatch to add an IP to a whitelist |
| Create | `.github/workflows/remove-ip-whitelist.yml` | workflow_dispatch to remove an IP from a whitelist |

---

## Chunk 1: NGINX Whitelist Files

### Task 1: Create `proxy/conf.d/whitelist.conf`

**Files:**
- Create: `proxy/conf.d/whitelist.conf`

- [ ] **Step 1: Create the file**

```nginx
# proxy/conf.d/whitelist.conf
# Defines per-service geo variables for IP whitelisting.
# Each protected service has its own geo variable so IPs are not shared across services.
#
# HOW TO ADD A NEW PROTECTED SERVICE:
#   1. Create proxy/conf.d/whitelist-<service>-ips.conf with a "# no entries" placeholder
#   2. Add a geo $allowed_<service> block here (include global + service IPs)
#   3. Add `if ($allowed_<service> = 0) { return 444; }` to the service's server block
#   4. Add the service name to the workflow_dispatch choices in both GitHub Actions workflows

geo $allowed_osint {
    default 0;
    include /etc/nginx/conf.d/whitelist-global.conf;
    include /etc/nginx/conf.d/whitelist-osint-ips.conf;
}
```

- [ ] **Step 2: Commit**

```bash
git add proxy/conf.d/whitelist.conf
git commit -m "feat(proxy): add geo whitelist config for osint service"
```

---

### Task 2: Create placeholder IP files

**Files:**
- Create: `proxy/conf.d/whitelist-global.conf`
- Create: `proxy/conf.d/whitelist-osint-ips.conf`

- [ ] **Step 1: Create `whitelist-global.conf`**

```
# proxy/conf.d/whitelist-global.conf
# IPs in this file are allowed on ALL protected services.
# Managed via GitHub Actions add-ip-whitelist / remove-ip-whitelist workflows.
# Format: <ip>  1;  # <reason>
# no entries
```

- [ ] **Step 2: Create `whitelist-osint-ips.conf`**

```
# proxy/conf.d/whitelist-osint-ips.conf
# IPs in this file are allowed ONLY on osint.corbello.io.
# Managed via GitHub Actions add-ip-whitelist / remove-ip-whitelist workflows.
# Format: <ip>  1;  # <reason>
# no entries
```

- [ ] **Step 3: Commit**

```bash
git add proxy/conf.d/whitelist-global.conf proxy/conf.d/whitelist-osint-ips.conf
git commit -m "feat(proxy): add empty IP whitelist files for global and osint"
```

---

### Task 3: Update `osint.corbello.io.conf` to enforce the whitelist

**Files:**
- Modify: `proxy/sites/osint.corbello.io.conf`

The current file's `location /` block has no access control. Add the geo variable check as the first line inside the block.

- [ ] **Step 1: Update the file**

Replace the existing `location /` block:

```nginx
# osint.corbello.io -> K3s Traefik -> osint-core API
server {
    server_name osint.corbello.io;

    client_max_body_size 10M;

    location / {
        if ($allowed_osint = 0) { return 444; }

        proxy_pass http://192.168.1.90:30278;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;
        proxy_read_timeout 120s;
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/osint.corbello.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/osint.corbello.io/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if ($host = osint.corbello.io) {
        return 301 https://$host$request_uri;
    }
    server_name osint.corbello.io;
    listen 80;
    return 404;
}
```

> **Warning:** The `if ($allowed_osint = 0) { return 444; }` block must contain **only** `return 444;`. Do not add any other directives inside the `if` block — NGINX's "if is evil" behavior makes additional directives in `if` unsafe.

- [ ] **Step 2: Commit**

```bash
git add proxy/sites/osint.corbello.io.conf
git commit -m "feat(proxy): enforce IP whitelist on osint.corbello.io"
```

---

### Task 4: Deploy to LXC 100 and verify

- [ ] **Step 1: Copy the new conf.d files to the proxy**

From your developer machine:

```bash
scp proxy/conf.d/whitelist.conf \
    proxy/conf.d/whitelist-global.conf \
    proxy/conf.d/whitelist-osint-ips.conf \
    root@192.168.1.100:/etc/nginx/conf.d/
```

- [ ] **Step 2: Copy the updated sites file**

```bash
scp proxy/sites/osint.corbello.io.conf root@192.168.1.100:/etc/nginx/sites-available/
```

- [ ] **Step 3: Test NGINX config**

```bash
ssh root@192.168.1.100 "nginx -t"
```

Expected output:
```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

If `nginx -t` fails, check `/var/log/nginx/error.log` on LXC 100 for the specific error. The most common cause is a missing include file — verify all three `whitelist*.conf` files are present in `/etc/nginx/conf.d/`.

- [ ] **Step 4: Reload NGINX**

```bash
ssh root@192.168.1.100 "nginx -s reload"
```

- [ ] **Step 5: Verify whitelist is active (from a non-whitelisted IP)**

From any machine **not** in the whitelist (e.g., a mobile hotspot or a VPS), attempt:

```bash
curl -v --max-time 10 https://osint.corbello.io
```

Expected: connection times out or is reset — no HTTP response headers returned.

- [ ] **Step 6: Verify access from a whitelisted IP**

Add your home IP temporarily to `whitelist-global.conf`:

```bash
echo "YOUR.HOME.IP  1;  # temp test" | ssh root@192.168.1.100 "cat >> /etc/nginx/conf.d/whitelist-global.conf && nginx -s reload"
```

Then verify `https://osint.corbello.io` loads normally.

Remove the test entry afterward:

```bash
ssh root@192.168.1.100 "sed -i '/temp test/d' /etc/nginx/conf.d/whitelist-global.conf && nginx -s reload"
```

---

## Chunk 2: ARC Runner for cortech-infra

### Task 5: Generate SSH keypair and provision LXC 100

This is a **one-time manual setup** that does not produce a committed artifact (the private key is never committed).

- [ ] **Step 1: Generate the keypair**

On your developer machine:

```bash
ssh-keygen -t ed25519 -C "cortech-infra-arc-runner" -f ~/.ssh/cortech_infra_arc_runner -N ""
```

This creates:
- `~/.ssh/cortech_infra_arc_runner` (private key — never commit)
- `~/.ssh/cortech_infra_arc_runner.pub` (public key)

- [ ] **Step 2: Add the public key to LXC 100**

```bash
cat ~/.ssh/cortech_infra_arc_runner.pub | ssh root@192.168.1.100 "cat >> /root/.ssh/authorized_keys"
```

- [ ] **Step 3: Capture the LXC 100 host key for `known_hosts`**

```bash
ssh-keyscan -H 192.168.1.100 > /tmp/proxy_known_hosts
```

Verify it captured a key (should be one non-comment line):

```bash
cat /tmp/proxy_known_hosts
```

Expected: one line starting with `|1|` (hashed hostname) followed by the key type and key data.

- [ ] **Step 4: Create the K8s Secret**

```bash
kubectl create secret generic cortech-infra-proxy-ssh-key \
  --from-file=id_ed25519=~/.ssh/cortech_infra_arc_runner \
  --from-file=known_hosts=/tmp/proxy_known_hosts \
  -n actions-runner-system
```

Verify:

```bash
kubectl get secret cortech-infra-proxy-ssh-key -n actions-runner-system
```

Expected:
```
NAME                          TYPE     DATA   AGE
cortech-infra-proxy-ssh-key   Opaque   2      <just now>
```

- [ ] **Step 5: Clean up local private key temp files (optional)**

```bash
rm /tmp/proxy_known_hosts
# Optionally also remove the local private key if you've saved it elsewhere securely
```

---

### Task 6: Create and apply the RunnerDeployment

**Files:**
- Create: `k8s/actions-runner-system/cortech-infra-runner.yaml`

- [ ] **Step 1: Create the manifest**

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: cortech-infra-runner
  namespace: actions-runner-system
spec:
  replicas: 1
  template:
    spec:
      repository: jacorbello/cortech-infra
      labels:
        - self-hosted
        - linux
        - cortech-infra-deploy
      resources:
        requests:
          cpu: 200m
          memory: 256Mi
          ephemeral-storage: 1Gi
        limits:
          cpu: "1"
          memory: 1Gi
          ephemeral-storage: 4Gi
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

- [ ] **Step 2: Apply the manifest**

```bash
ssh root@192.168.1.52 "kubectl apply -f -" < k8s/actions-runner-system/cortech-infra-runner.yaml
```

- [ ] **Step 3: Verify the runner pod starts**

```bash
ssh root@192.168.1.52 "kubectl get pods -n actions-runner-system -l actions-runner=cortech-infra-runner"
```

Wait for `2/2 Running`. If the pod fails to start, check:

```bash
ssh root@192.168.1.52 "kubectl describe pod -n actions-runner-system -l actions-runner=cortech-infra-runner"
```

- [ ] **Step 4: Verify the runner appears in GitHub**

Navigate to `https://github.com/jacorbello/cortech-infra/settings/actions/runners` and confirm a runner with label `cortech-infra-deploy` is listed as **Idle**.

- [ ] **Step 5: Verify SSH key permissions inside the runner**

Exec into the runner pod and check:

```bash
RUNNER_POD=$(ssh root@192.168.1.52 "kubectl get pod -n actions-runner-system -l actions-runner=cortech-infra-runner -o name | head -1")
ssh root@192.168.1.52 "kubectl exec -n actions-runner-system $RUNNER_POD -c runner -- ls -la /secrets/"
```

Expected: both `id_ed25519` and `known_hosts` with permissions `-rw-------` (0600).

- [ ] **Step 6: Smoke-test SSH from runner to proxy**

```bash
ssh root@192.168.1.52 "kubectl exec -n actions-runner-system $RUNNER_POD -c runner -- \
  ssh -i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts \
  root@192.168.1.100 'hostname'"
```

Expected output: `proxy` (or whatever the LXC 100 hostname is). If this fails, check:
- `/root/.ssh/authorized_keys` on LXC 100 contains the public key
- The secret was created with the correct private key
- `defaultMode: 0600` is set on the secret volume

- [ ] **Step 7: Commit the manifest**

```bash
git add k8s/actions-runner-system/cortech-infra-runner.yaml
git commit -m "feat(k8s): add ARC runner for cortech-infra repo"
```

---

## Chunk 3: GitHub Actions Workflows

### Task 7: Create `add-ip-whitelist.yml`

**Files:**
- Create: `.github/workflows/add-ip-whitelist.yml`

- [ ] **Step 1: Create the workflow**

```yaml
name: Add IP to Whitelist

on:
  workflow_dispatch:
    inputs:
      ip:
        description: 'IPv4 address to allow (e.g. 203.0.113.5)'
        required: true
        type: string
      service:
        description: 'Service to whitelist IP for'
        required: true
        type: choice
        options:
          - global
          - osint
      reason:
        description: 'Short description (used in commit message and as comment)'
        required: true
        type: string

permissions:
  contents: write

jobs:
  add-ip:
    runs-on: [self-hosted, linux, cortech-infra-deploy]
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: true

      - name: Validate IPv4 address
        run: |
          if ! echo "${{ inputs.ip }}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            echo "::error::Invalid IPv4 address: ${{ inputs.ip }}"
            exit 1
          fi
          IFS='.' read -ra OCTETS <<< "${{ inputs.ip }}"
          for octet in "${OCTETS[@]}"; do
            if [ "$octet" -gt 255 ]; then
              echo "::error::Invalid IPv4 address: octet $octet is out of range (0-255)"
              exit 1
            fi
          done

      - name: Determine target file
        id: target
        run: |
          if [ "${{ inputs.service }}" = "global" ]; then
            echo "file=proxy/conf.d/whitelist-global.conf" >> "$GITHUB_OUTPUT"
          else
            echo "file=proxy/conf.d/whitelist-${{ inputs.service }}-ips.conf" >> "$GITHUB_OUTPUT"
          fi

      - name: Check for duplicate
        id: check
        run: |
          ESCAPED_IP=$(echo "${{ inputs.ip }}" | sed 's/\./\\./g')
          if grep -qE "^${ESCAPED_IP}[[:space:]]" "${{ steps.target.outputs.file }}"; then
            echo "::notice::IP ${{ inputs.ip }} already present in ${{ steps.target.outputs.file }} — skipping"
            echo "already_present=true" >> "$GITHUB_OUTPUT"
          else
            echo "already_present=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Append IP entry
        if: steps.check.outputs.already_present == 'false'
        run: |
          echo "${{ inputs.ip }}  1;  # ${{ inputs.reason }}" >> "${{ steps.target.outputs.file }}"

      - name: Commit and push
        if: steps.check.outputs.already_present == 'false'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add "${{ steps.target.outputs.file }}"
          git commit -m "chore(proxy): allow ${{ inputs.ip }} on ${{ inputs.service }} — ${{ inputs.reason }}"
          git push

      - name: Sync whitelist files to proxy
        if: steps.check.outputs.already_present == 'false'
        run: |
          rsync -av \
            -e "ssh -i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts" \
            proxy/conf.d/whitelist*.conf \
            root@192.168.1.100:/etc/nginx/conf.d/

      - name: Test and reload NGINX
        if: steps.check.outputs.already_present == 'false'
        run: |
          ssh -i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts \
            root@192.168.1.100 "nginx -t && nginx -s reload"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/add-ip-whitelist.yml
git commit -m "feat(ci): add workflow to add IPs to NGINX whitelist"
```

---

### Task 8: Create `remove-ip-whitelist.yml`

**Files:**
- Create: `.github/workflows/remove-ip-whitelist.yml`

- [ ] **Step 1: Create the workflow**

```yaml
name: Remove IP from Whitelist

on:
  workflow_dispatch:
    inputs:
      ip:
        description: 'IPv4 address to remove (e.g. 203.0.113.5)'
        required: true
        type: string
      service:
        description: 'Service to remove IP from'
        required: true
        type: choice
        options:
          - global
          - osint
      reason:
        description: 'Short description (used in commit message)'
        required: true
        type: string

permissions:
  contents: write

jobs:
  remove-ip:
    runs-on: [self-hosted, linux, cortech-infra-deploy]
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: true

      - name: Validate IPv4 address
        run: |
          if ! echo "${{ inputs.ip }}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            echo "::error::Invalid IPv4 address: ${{ inputs.ip }}"
            exit 1
          fi
          IFS='.' read -ra OCTETS <<< "${{ inputs.ip }}"
          for octet in "${OCTETS[@]}"; do
            if [ "$octet" -gt 255 ]; then
              echo "::error::Invalid IPv4 address: octet $octet is out of range (0-255)"
              exit 1
            fi
          done

      - name: Determine target file
        id: target
        run: |
          if [ "${{ inputs.service }}" = "global" ]; then
            echo "file=proxy/conf.d/whitelist-global.conf" >> "$GITHUB_OUTPUT"
          else
            echo "file=proxy/conf.d/whitelist-${{ inputs.service }}-ips.conf" >> "$GITHUB_OUTPUT"
          fi

      - name: Check IP is present
        run: |
          ESCAPED_IP=$(echo "${{ inputs.ip }}" | sed 's/\./\\./g')
          if ! grep -qE "^${ESCAPED_IP}[[:space:]]" "${{ steps.target.outputs.file }}"; then
            echo "::error::IP ${{ inputs.ip }} not found in ${{ steps.target.outputs.file }}"
            echo "::error::Only exact IPv4 entries are supported — CIDR ranges must be removed manually"
            exit 1
          fi

      - name: Remove IP entry
        run: |
          ESCAPED_IP=$(echo "${{ inputs.ip }}" | sed 's/\./\\./g')
          sed -i "/^${ESCAPED_IP}[[:space:]]/d" "${{ steps.target.outputs.file }}"

      - name: Commit and push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add "${{ steps.target.outputs.file }}"
          git commit -m "chore(proxy): remove ${{ inputs.ip }} from ${{ inputs.service }} — ${{ inputs.reason }}"
          git push

      - name: Sync whitelist files to proxy
        run: |
          rsync -av \
            -e "ssh -i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts" \
            proxy/conf.d/whitelist*.conf \
            root@192.168.1.100:/etc/nginx/conf.d/

      - name: Test and reload NGINX
        run: |
          ssh -i /secrets/id_ed25519 -o UserKnownHostsFile=/secrets/known_hosts \
            root@192.168.1.100 "nginx -t && nginx -s reload"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/remove-ip-whitelist.yml
git commit -m "feat(ci): add workflow to remove IPs from NGINX whitelist"
```

---

### Task 9: End-to-end workflow test

- [ ] **Step 1: Trigger `add-ip-whitelist` via GitHub UI**

Go to `https://github.com/jacorbello/cortech-infra/actions/workflows/add-ip-whitelist.yml` → Run workflow.

Inputs:
- `ip`: a real IP you control (your home IP or VPN exit)
- `service`: `global`
- `reason`: `e2e test`

- [ ] **Step 2: Verify the workflow run succeeds**

All steps should be green. Check that:
- A commit was pushed with message `chore(proxy): allow <ip> on global — e2e test`
- NGINX reloaded without error

- [ ] **Step 3: Verify access from the whitelisted IP**

From the whitelisted IP, confirm `https://osint.corbello.io` loads normally.

- [ ] **Step 4: Trigger `add-ip-whitelist` again with the same IP (duplicate test)**

Run the workflow with the same IP. The `Check for duplicate` step should emit a notice and all subsequent steps should be skipped. No new commit should be pushed.

- [ ] **Step 5: Trigger `remove-ip-whitelist`**

Go to `https://github.com/jacorbello/cortech-infra/actions/workflows/remove-ip-whitelist.yml` → Run workflow with the same IP, service `global`, reason `e2e test cleanup`.

Verify:
- Workflow succeeds
- A commit was pushed removing the line
- `https://osint.corbello.io` is now inaccessible from that IP (444 / timeout)

- [ ] **Step 6: Trigger `remove-ip-whitelist` with a non-existent IP (error test)**

Run with an IP that is not in any file. The `Check IP is present` step should fail with a clear error message. No commit should be pushed.

- [ ] **Step 7: Note on service isolation test**

The spec requires confirming that an IP added to `whitelist-osint-ips.conf` is not accessible on any other protected service. This test is **deferred** until a second protected service is onboarded — the `geo` variable isolation is structural (each service has its own `$allowed_<service>` variable sourcing only its own IP file), so the test will be run as part of the second service's onboarding. Document in the PR description that this test is pending.
