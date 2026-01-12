# Cortech Homelab Infrastructure

Infrastructure-as-code for the Cortech homelab running on Proxmox, with Kubernetes workloads and GitHub Actions runners hosted on Proxmox. DNS for corbello.io is managed as code; ingress terminates TLS on the `proxy` LXC (PCT 100).

## Repo Layout
- `proxmox/` — VM/LXC definitions, cloud-init, templates.
- `pct/` — Container specs and helpers for `pct` workflows.
- `proxy/` — NGINX and certbot config for PCT 100 (`proxy`).
- `dns/` — Namecheap DNS as code (prefer Terraform) for `*.corbello.io`.
- `ansible/` — Roles/playbooks to configure guests.
- `scripts/` — Repeatable ops tasks (create/backup/restore, health checks).
- `test/` — Terratest/Bats and validation utilities.
- `docs/` — Diagrams, runbooks, ADRs.

## Anticipated Tools
- Core IaC: `terraform`, Proxmox and Namecheap providers, `tflint`, `pre-commit`.
- Proxmox: `pvesh`, `qm`, `pct`, `cloud-init` helpers, optional `packer` for templates.
- Kubernetes: `k3s` or `kubeadm`, `kubectl`, `helm`, optional `argocd`, `cilium`/`calico`, `metallb`/`kube-vip` (L2/VRRP).
- CI/CD: GitHub Actions, self‑hosted runners on Proxmox (systemd or ARC).
- Ingress & DNS: `nginx` (reverse proxy), `certbot` (Let’s Encrypt), Terraform Namecheap provider.
- Config Mgmt: `ansible`, `ansible-lint`.
- Security & Secrets: `sops` (age/GPG), HashiCorp `vault` (optional), `age`.
- Testing & QA: `go` (Terratest), `bats-core`, `yamllint`, `shellcheck`, `shfmt`.

## Getting Started
- Install: Terraform, Go (for tests), Ansible, pre-commit, shell tooling (shellcheck, shfmt), and TFLint.
- Initialize tooling and hooks: `make init`
- Format HCL/YAML/shell: `make fmt`
- Lint Terraform/Ansible/YAML/shell: `make lint`
- Plan/apply Terraform for an env: `make plan ENV=dev` then `make apply ENV=dev`

Example (direct Terraform): `terraform plan -var-file=environments/dev/terraform.tfvars`

## Inventory & Diagram
- Refresh inventory and Mermaid diagram from a Proxmox node: `make inventory`
- Outputs: `docs/inventory.md`, `docs/diagram.md`

## Conventions
- Indentation: 2 spaces for HCL/YAML; no tabs.
- Bash: `set -Eeuo pipefail`; format with `shfmt`; lint with `shellcheck`.
- Naming: lowercase-hyphenated (e.g., `service-api`, `vpc-core`, `media-proxy`).
- Terraform modules: keep small and idempotent; include `variables.tf`, `outputs.tf`, `versions.tf` per module.

## Security
- Never commit secrets. Use SOPS/Vault; commit only encrypted files.
- TLS is managed by certbot on `proxy` (PCT 100); route 80/443 through it.
- DNS is managed via code under `dns/`; avoid manual drift in Namecheap.

## Commits & PRs
- Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`).
- PRs include summary, linked issue, risk/rollback, `terraform plan` output, and URLs/screenshots for `https://<service>.corbello.io` when relevant.

