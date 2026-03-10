# GSoC Project 5: Complete Local-Verifiable Helm PoC (Katib + KFP)

## Summary
This change packages a complete Project 5 PoC into one branch and one verification entrypoint.

It includes:
- Katib Helm parity repair with full 7-scenario comparison coverage.
- Kubeflow Pipelines Helm PoC with parity coverage for:
  - `platform-agnostic-multi-user`
  - `platform-agnostic-multi-user-k8s-native`
- One-place wrappers for local verification:
  - `make verify`
  - `make setup-kind-prereqs`
  - `make verify-runtime`

## Why This Exists
The goal is to provide a single branch that anyone can clone and validate locally without searching across multiple repos/worktrees.

## Main Paths
- PoC guide: `gsoc-poc/README.md`
- PoC structure map: `gsoc-poc/STRUCTURE.md`
- Parity wrapper: `gsoc-poc/scripts/verify-parity.sh`
- Cluster prerequisites wrapper: `gsoc-poc/scripts/setup-kind-prereqs.sh`
- Runtime wrapper: `gsoc-poc/scripts/verify-runtime.sh`
- Katib chart: `experimental/helm/charts/katib`
- Pipelines chart: `experimental/helm/charts/pipelines`
- Compare scripts:
  - `tests/helm_kustomize_compare.sh`
  - `tests/helm_kustomize_compare_all.sh`
  - `tests/helm_kustomize_compare.py`

## Validation Executed
### 1. Parity
Command:
```bash
make verify
```
Result:
- Katib: all 7 scenarios passed.
- Pipelines:
  - `platform-agnostic-multi-user` passed.
  - `platform-agnostic-multi-user-k8s-native` passed.

### 2. Prerequisite Cluster Setup
Command:
```bash
make setup-kind-prereqs
```
Result:
- Kind cluster created/reused.
- cert-manager and Istio prerequisites installed and ready.

### 3. Runtime Validation
Command:
```bash
make verify-runtime
```
Result:
- `multi-user` scenario: deployed and runtime checks passed.
- `k8s-native` scenario: deployed and runtime checks passed.

## Reproduce Locally
```bash
git clone https://github.com/danish9039/manifests.git
cd manifests
git checkout gsoc/project5-complete-poc
make verify
make setup-kind-prereqs
make verify-runtime
```

## Scope Boundary
- This is a local-only PoC for validating implementation feasibility and proposal claims.
- It is not claiming production readiness across all environments.

## Known Notes
- Parity checks may print non-blocking Kustomize warnings for unreplaced vars (`kfp-app-name`, `kfp-app-version`).
- First runtime install on a fresh node can be slower due to image pulls; wrapper defaults include timing guards:
  - `KUSTOMIZE_GIT_TIMEOUT=180s` in compare flow
  - `HELM_TIMEOUT=25m` in runtime wrapper

## Checklist
- [x] Katib parity matrix green.
- [x] KFP parity scenarios green.
- [x] Runtime install checks green for both KFP scenarios.
- [x] One-place docs and scripts added under `gsoc-poc/`.
