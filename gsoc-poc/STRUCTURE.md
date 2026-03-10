# Project 5 PoC Structure Map

This branch contains both Project 5 PoC tracks in one place:
- Katib parity track
- Kubeflow Pipelines parity + runtime track

## Main Paths

### Katib
- Chart: `experimental/helm/charts/katib`
- Baseline: `applications/katib/upstream/installs/*`
- Scenarios:
  - `standalone`
  - `cert-manager`
  - `external-db`
  - `leader-election`
  - `openshift`
  - `standalone-postgres`
  - `with-kubeflow`

### Pipelines
- Chart: `experimental/helm/charts/pipelines`
- Baseline: `applications/pipeline/upstream/env/cert-manager/*`
- Scenarios:
  - `platform-agnostic-multi-user`
  - `platform-agnostic-multi-user-k8s-native`

### Compare and validation wiring
- Compare runner: `tests/helm_kustomize_compare.sh`
- Matrix runner: `tests/helm_kustomize_compare_all.sh`
- Diff engine: `tests/helm_kustomize_compare.py`
- Wrapper scripts:
  - `gsoc-poc/scripts/verify-parity.sh`
  - `gsoc-poc/scripts/setup-kind-prereqs.sh`
  - `gsoc-poc/scripts/verify-runtime.sh`
- Root shortcuts:
  - `make verify`
  - `make setup-kind-prereqs`
  - `make verify-runtime`

## Verification Commands

### Parity
```bash
make verify
```

### Runtime
```bash
make setup-kind-prereqs
make verify-runtime
```

## Notes
- `tests/helm_kustomize_compare.sh` sets `KUSTOMIZE_GIT_TIMEOUT=180s` by default to reduce flaky remote-fetch timeouts during Kustomize builds.
- Runtime verification uses `HELM_TIMEOUT=25m` by default to tolerate first-run image pulls on fresh local clusters.
