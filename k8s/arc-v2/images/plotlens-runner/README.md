# plotlens-runner

Custom ARC v2 runner image for the PlotLens repo. Extends the GitHub Actions
runner with Tauri system dependencies pre-installed, eliminating the need for
`apt-get install` during CI runs.

## Baked-in Dependencies

Source: `Family-Friendly-Inc/plotlens/.github/workflows/ci.yaml` ("Install Linux dependencies" step)

- libwebkit2gtk-4.1-dev
- libappindicator3-dev
- librsvg2-dev
- patchelf
- libgtk-3-dev
- libsoup-3.0-dev
- libjavascriptcoregtk-4.1-dev

## Build

From the Proxmox master (192.168.1.52), which has Podman available:

    podman build -t harbor.corbello.io/arc/plotlens-runner:v1 \
      -f Containerfile .

## Push

    podman push harbor.corbello.io/arc/plotlens-runner:v1

Requires Harbor login:

    podman login harbor.corbello.io

## Update Workflow

1. Update the base image tag or package list in `Containerfile`
2. Bump the version tag (e.g., `v1` -> `v2`)
3. Build and push the new image
4. Update `k8s/arc-v2/plotlens-runner-values.yaml` to reference the new tag
5. Apply: `helm upgrade plotlens-runner oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set -n arc-runners -f k8s/arc-v2/plotlens-runner-values.yaml`

## Keeping in Sync

If the plotlens CI workflow's "Install Linux dependencies" step changes, this
image must be rebuilt to match. The Containerfile package list should mirror
that step exactly.
