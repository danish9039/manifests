# KServe Helm Chart

This chart renders the current Kubeflow KServe Kustomize resources with Helm.
It is intentionally static for the first platform slice so the rendered output
stays aligned with `applications/kserve/kserve`.

## Install

Install the foundation charts, cert-manager, Istio, and Knative Serving first.
KServe is installed in two steps because KServe custom resources cannot be
created until the KServe CRDs exist. The CRDs live in the chart `crds/`
directory, so Helm installs them before templates and does not delete them on
uninstall.

```bash
helm install kserve ./experimental/helm/charts/kserve \
  --namespace kubeflow \
  --values ./experimental/helm/charts/kserve/ci/values-crds.yaml \
  --wait

helm upgrade kserve ./experimental/helm/charts/kserve \
  --namespace kubeflow \
  --values ./experimental/helm/charts/kserve/ci/values-platform.yaml \
  --wait
```

Helm release metadata is stored in `kubeflow`. KServe workloads also run in
`kubeflow`, matching the current Kustomize install path.

Keep `global.kubeflowNamespace` set to `kubeflow` in this first slice. KServe
CRDs live under Helm `crds/`, and Helm does not template files in that
directory, so the CRD webhook and cert-manager namespace references remain
fixed to the current Kustomize namespace.

## Kustomize Mapping

- `ci/values-crds.yaml`: CRD-only subset of `applications/kserve/kserve`
- `ci/values-platform.yaml`: non-CRD resources from `applications/kserve/kserve`; render with `--include-crds` for full Kustomize parity

`models-web-app`, standalone/raw KServe, upstream Helm dependency mode, and
existing/shared KServe modes are intentionally deferred to later chart slices.

## Regenerate Static Manifests

Run from the repository root:

```bash
kustomize build applications/kserve/kserve > /tmp/kserve-platform.yaml

python3 - /tmp/kserve-platform.yaml \
  experimental/helm/charts/kserve/crds/kserve.yaml \
  experimental/helm/charts/kserve/manifests/platform.yaml <<'PY'
import sys
import yaml

source, crds_path, platform_path = sys.argv[1:]
with open(source) as f:
    docs = [doc for doc in yaml.safe_load_all(f) if doc]
crds = [doc for doc in docs if doc.get("kind") == "CustomResourceDefinition"]
non_crds = [doc for doc in docs if doc.get("kind") != "CustomResourceDefinition"]
with open(crds_path, "w") as f:
    yaml.safe_dump_all(crds, f, sort_keys=False)
with open(platform_path, "w") as f:
    yaml.safe_dump_all(non_crds, f, sort_keys=False)
PY
```

## Comparison

```bash
helm lint experimental/helm/charts/kserve
./tests/helm_kustomize_compare.sh kserve crds
./tests/helm_kustomize_compare.sh kserve platform
```
