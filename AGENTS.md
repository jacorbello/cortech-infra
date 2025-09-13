# Repository Guidelines

## Project Structure & Module Organization
- `proxmox/`: VM/LXC definitions, cloud-init snippets, templates.
- `pct/`: Container specs and helpers for `pct` workflows.
- `proxy/`: NGINX and certbot config for PCT 100 (`proxy`).
- `dns/`: Namecheap DNS as code (prefer Terraform) for `*.corbello.io`.
- `ansible/`: Roles/playbooks to configure guests.
- `scripts/`: Repeatable ops tasks (create/backup/restore, health checks).
- `test/`: Terratest/Bats and validation utilities.
- `docs/`: Diagrams, runbooks, and ADRs.

## Build, Test, and Development Commands
- `make init` — bootstrap tools (terraform init, pre-commit).
- `make fmt` — format HCL/YAML/shell.
- `make lint` — run `tflint`, `ansible-lint`, `yamllint`, `shellcheck`.
- `make plan ENV=dev` — terraform plan for an environment.
- `make apply ENV=dev` — apply infra changes (manual approval).
- Example: `terraform plan -var-file=environments/dev/terraform.tfvars`
- Example: `scripts/pct/create.sh 101 media` (LXC id 101, role “media”).

## Coding Style & Naming Conventions
- Indentation: 2 spaces for HCL/YAML; no tabs.
- Bash: `set -Eeuo pipefail`; format with `shfmt`; lint with `shellcheck`.
- Names: lowercase-hyphenated (e.g., `service-api`, `vpc-core`, `media-proxy`).
- Terraform: `variables.tf`, `outputs.tf`, `versions.tf` per module; small, idempotent modules.

## Testing Guidelines
- Run `make test` locally (validate + unit/integration).
- Terratest under `test/terratest/<module>/...`.
- Bats for scripts under `test/bats/`; name `<tool>_test.bats`.
- Aim for ≥80% critical-path coverage; include plan/apply dry-runs in CI.

## Commit & Pull Request Guidelines
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`.
- PRs include: summary, linked issue, risk/rollback, `terraform plan` output, and if applicable a screenshot/URL of `https://<service>.corbello.io`.
- Keep PRs focused; one logical change.

## Security & Configuration Tips
- No secrets in git. Use SOPS/Vault; commit only encrypted files.
- Certs managed by certbot on `proxy` (PCT 100); route 80/443 there.
- DNS: manage via `dns/` and apply at Namecheap; avoid manual drift.
- GPU node `cortech-node5` is usually off—note requirements before enabling.

## Agent-Specific Instructions
- Make minimal, surgical changes; don’t refactor unrelated code.
- Use `apply_patch` and follow these conventions for any touched files.
