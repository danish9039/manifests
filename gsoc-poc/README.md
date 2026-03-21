# Project 5 Complete PoC (GSoC 2026)

This branch packages the full Project 5 proof-of-concept in one place so anyone can verify locally.

## What Is Included

### Core Parity and Runtime Validation
- Katib Helm parity repair and full 7-scenario comparison support.
- Kubeflow Pipelines (KFP) Helm PoC chart + parity support for:
  - `platform-agnostic-multi-user`
  - `platform-agnostic-multi-user-k8s-native`
- One-command wrappers under `gsoc-poc/scripts/`.

### Idea 1: Scheduled Baseline Drift Detection
- Script: `experimental/helm/scripts/check-drift.sh`
- Workflow: `.github/workflows/helm-drift-detection.yml`
- Renders Helm from the current checkout, builds the Kustomize baseline from a temporary `master` worktree, and compares both outputs using the existing compare harness.
- Runs weekly on schedule and supports manual dispatch.
- When drift is detected the workflow uploads per-scenario diff artifacts and opens or updates a triage issue.

### Idea 2: Render-Only Schema Validation
- Script: `experimental/helm/scripts/validate-schema.sh`
- Workflow: `.github/workflows/helm-schema-validation.yml`
- Runs `helm lint` followed by `helm template | kubeconform -strict -ignore-missing-schemas` for all 9 supported Project 5 scenarios.
- Catches duplicate YAML keys, malformed rendered resources, and structural defects that parity checks alone do not surface.
- All 9 scenarios pass after template repair committed in this branch.

## Repository Areas Used By This PoC

| Area | Path |
| --- | --- |
| Katib chart | `experimental/helm/charts/katib` |
| KFP chart | `experimental/helm/charts/pipelines` |
| Katib Kustomize baseline | `applications/katib/upstream/installs/*` |
| KFP Kustomize baseline | `applications/pipeline/upstream/env/cert-manager/*` |
| Compare scripts | `tests/helm_kustomize_compare.sh`, `tests/helm_kustomize_compare_all.sh`, `tests/helm_kustomize_compare.py` |
| PoC wrappers | `gsoc-poc/scripts/*` |
| Drift detection | `experimental/helm/scripts/check-drift.sh`, `.github/workflows/helm-drift-detection.yml` |
| Schema validation | `experimental/helm/scripts/validate-schema.sh`, `.github/workflows/helm-schema-validation.yml` |

## Prerequisites

```
bash, python3, kubectl, helm, kustomize, git
```
For runtime checks: `kind`, `curl`
For schema validation (Idea 2): [`kubeconform`](https://github.com/yannh/kubeconform) v0.6.4+

Recommended versions are listed in `gsoc-poc/tool-versions.env`.

---

## Quick Start: Parity Checks Only

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

---

## Runtime Validation (Local Cluster)

```bash
make setup-kind-prereqs
make verify-runtime
```

By default `verify-runtime` runs both KFP runtime scenarios (`multi-user` and `k8s-native`) and two representative Katib runtime scenarios (`standalone` and `with-kubeflow`).

Run one scenario directly:
```bash
./gsoc-poc/scripts/verify-runtime.sh multi-user
./gsoc-poc/scripts/verify-runtime.sh k8s-native
```

---

## Idea 1: Drift Detection

Checks whether Helm renders have drifted from the current upstream Kustomize baseline on `master`.

### Run a single scenario

```bash
# ensure git has fetched origin
git fetch origin master

experimental/helm/scripts/check-drift.sh standalone
experimental/helm/scripts/check-drift.sh platform-agnostic-multi-user
```

### Run all 9 Project 5 scenarios

```bash
for scenario in \
  platform-agnostic-multi-user \
  platform-agnostic-multi-user-k8s-native \
  standalone \
  cert-manager \
  external-db \
  leader-election \
  openshift \
  standalone-postgres \
  with-kubeflow; do
  echo "==> $scenario"
  experimental/helm/scripts/check-drift.sh "$scenario" 2>&1 | tail -3
  echo ""
done
```

### Local validation results

| Scenario | Result | Notes |
| --- | --- | --- |
| `platform-agnostic-multi-user` | **FAIL** | drift in 11 resources — known open KFP parity gap |
| `platform-agnostic-multi-user-k8s-native` | **FAIL** | drift in 11 resources — known open KFP parity gap |
| `standalone` | PASS | no drift against master |
| `cert-manager` | PASS | no drift against master |
| `external-db` | PASS | no drift against master |
| `leader-election` | PASS | no drift against master |
| `openshift` | PASS | no drift against master |
| `standalone-postgres` | PASS | no drift against master |
| `with-kubeflow` | PASS | no drift against master |

The two KFP failures are the known open parity gap that this proposal targets. All 7 Katib scenarios are already drift-free against the current upstream baseline.

### Optional: save JSON result files

```bash
DRIFT_RESULTS_DIR=/tmp/drift-results \
  experimental/helm/scripts/check-drift.sh standalone
cat /tmp/drift-results/standalone.json
```

---

## Idea 2: Schema Validation

Validates that rendered Helm manifests pass `helm lint` and `kubeconform -strict`.

### Install kubeconform (one-time)

```bash
# Linux amd64 — see https://github.com/yannh/kubeconform/releases for other platforms
curl -sSL https://github.com/yannh/kubeconform/releases/download/v0.6.4/kubeconform-linux-amd64.tar.gz \
  | tar -xz -C /usr/local/bin kubeconform
```

### Run a single scenario

```bash
# KFP — platform-agnostic-multi-user
experimental/helm/scripts/validate-schema.sh \
  experimental/helm/charts/pipelines \
  experimental/helm/charts/pipelines/ci/values-platform-agnostic-multi-user.yaml

# Katib — standalone
experimental/helm/scripts/validate-schema.sh \
  experimental/helm/charts/katib \
  experimental/helm/charts/katib/ci/values-standalone.yaml
```

### Local validation results (all 9 scenarios)

| Scenario | helm lint | kubeconform |
| --- | --- | --- |
| KFP / platform-agnostic-multi-user | PASS | PASS |
| KFP / platform-agnostic-multi-user-k8s-native | PASS | PASS |
| Katib / standalone | PASS | PASS |
| Katib / cert-manager | PASS | PASS |
| Katib / external-db | PASS | PASS |
| Katib / leader-election | PASS | PASS |
| Katib / openshift | PASS | PASS |
| Katib / standalone-postgres | PASS | PASS |
| Katib / with-kubeflow | PASS | PASS |

All 9 scenarios pass after template repairs committed in this branch. The repairs removed duplicate label and annotation keys that were present in both the Helm helper-generated label block and manual label additions in the same template.

---

## Notes

- Validation scope is local-only PoC feasibility.
- A non-blocking Kustomize warning may appear for unreplaced vars (`kfp-app-name`, `kfp-app-version`) during parity checks.
- The drift-detection workflow requires `issues: write` permission on the repository to open or update triage issues.
- The schema-validation workflow does not require cluster access; it is render-only.
