# Kubeflow Trainer Helm Chart

This chart renders the current Kubeflow Trainer Kustomize resources with Helm.
It is intentionally static for the first platform slice so the rendered output
stays aligned with `applications/trainer/overlays`.

## Install

Install the foundation charts first. Trainer is installed in two steps because
Trainer runtime resources cannot be created until the Trainer CRDs exist. The
JobSet CRD is included in the same CRD step because the current platform
overlay bundles JobSet with Trainer.

```bash
helm install kubeflow-trainer ./experimental/helm/charts/kubeflow-trainer \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/kubeflow-trainer/ci/values-crds.yaml \
  --wait

helm upgrade kubeflow-trainer ./experimental/helm/charts/kubeflow-trainer \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/kubeflow-trainer/ci/values-platform.yaml \
  --wait
```

Helm release metadata is stored in `kubeflow-system`. Trainer and JobSet
controller workloads also run in `kubeflow-system`, matching the current
Kustomize install path.

CRDs live under Helm `crds/`, so Helm installs them before templates and does
not delete them on uninstall.

## Kustomize Mapping

- `ci/values-crds.yaml`: CRD-only subset of `applications/trainer/overlays`
- `ci/values-platform.yaml`: non-CRD resources from `applications/trainer/overlays`; render with `--include-crds` for full Kustomize parity

Standalone Trainer mode, the upstream Trainer Helm chart dependency mode,
data-cache / LeaderWorkerSet, existing JobSet mode, metrics, and dashboard
add-ons are intentionally deferred to later chart slices.

## Regenerate Static Manifests

Run from the repository root:

```bash
kustomize build applications/trainer/overlays > /tmp/kubeflow-trainer-platform.yaml

python3 - /tmp/kubeflow-trainer-platform.yaml \
  experimental/helm/charts/kubeflow-trainer/crds/trainer.yaml \
  experimental/helm/charts/kubeflow-trainer/manifests/platform.yaml <<'PY'
import sys
import yaml

source, crds_path, platform_path = sys.argv[1:]
with open(source) as f:
    docs = [doc for doc in yaml.safe_load_all(f) if doc]
crds = [doc for doc in docs if doc.get("kind") == "CustomResourceDefinition"]
platform = [doc for doc in docs if doc.get("kind") != "CustomResourceDefinition"]
with open(crds_path, "w") as f:
    yaml.safe_dump_all(crds, f, sort_keys=False)
with open(platform_path, "w") as f:
    yaml.safe_dump_all(platform, f, sort_keys=False)
PY
```

## Comparison

```bash
helm lint experimental/helm/charts/kubeflow-trainer
./tests/helm_kustomize_compare.sh kubeflow-trainer crds
./tests/helm_kustomize_compare.sh kubeflow-trainer platform
```
