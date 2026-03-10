# Project 5 Complete PoC (GSoC 2026)

This branch packages the full Project 5 proof-of-concept in one place so anyone can verify locally.

## What Is Included
- Katib Helm parity repair and full 7-scenario comparison support.
- Kubeflow Pipelines Helm PoC chart + parity support for:
  - `platform-agnostic-multi-user`
  - `platform-agnostic-multi-user-k8s-native`
- One command wrappers under `gsoc-poc/scripts/`.

## Repository Areas Used By This PoC
- Katib chart: `experimental/helm/charts/katib`
- KFP chart: `experimental/helm/charts/pipelines`
- Katib baseline: `applications/katib/upstream/installs/*`
- KFP baseline: `applications/pipeline/upstream/env/cert-manager/*`
- Compare scripts: `tests/helm_kustomize_compare.sh`, `tests/helm_kustomize_compare_all.sh`, `tests/helm_kustomize_compare.py`
- PoC wrappers: `gsoc-poc/scripts/*`

## Prerequisites
- `bash`
- `python3`
- `kubectl`
- `helm`
- `kustomize`
- for runtime checks: `kind`, `curl`

Recommended versions are listed in `gsoc-poc/tool-versions.env`.

## Quick Start (Parity Only)
```bash
git clone https://github.com/<YOUR_GITHUB_USER>/manifests.git
cd manifests
git checkout gsoc/project5-complete-poc
make verify
```

This runs:
- Katib: `./tests/helm_kustomize_compare_all.sh katib`
- KFP:
  - `./tests/helm_kustomize_compare.sh pipelines platform-agnostic-multi-user`
  - `./tests/helm_kustomize_compare.sh pipelines platform-agnostic-multi-user-k8s-native`

## Runtime Validation (Local Cluster)
```bash
make setup-kind-prereqs
make verify-runtime
```

By default `verify-runtime` runs both KFP runtime scenarios (`multi-user` and `k8s-native`).

You can run one scenario directly:
```bash
./gsoc-poc/scripts/verify-runtime.sh multi-user
./gsoc-poc/scripts/verify-runtime.sh k8s-native
```

## Notes
- Validation scope is local-only PoC feasibility.
- A non-blocking Kustomize warning may appear for unreplaced vars (`kfp-app-name`, `kfp-app-version`) during parity checks.
