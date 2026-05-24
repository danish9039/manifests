# Knative Serving Helm Chart

This chart renders the current Kubeflow Knative Serving Kustomize resources
with Helm. It is intentionally static for the first platform slice so the
rendered output stays aligned with the generated manifests under
`common/knative`.

## Install

Install the foundation charts, cert-manager, and Istio first. Knative Serving
is installed in two steps because Knative custom resources cannot be created
until the Knative Serving CRDs exist. The CRDs live in the chart `crds/`
directory, so Helm installs them before templates and does not delete them on
uninstall.

```bash
helm install knative-serving ./experimental/helm/charts/knative-serving \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/knative-serving/ci/values-crds.yaml \
  --wait

helm upgrade knative-serving ./experimental/helm/charts/knative-serving \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/knative-serving/ci/values-platform.yaml \
  --wait
```

Helm release metadata is stored in `kubeflow-system`. Knative Serving workloads
still run in `knative-serving`, and the local gateway service still lives in
`istio-system`.

The `knative-serving` namespace and the two bootstrap Knative custom resources
`Image/queue-proxy` and `Certificate/routing-serving-certs` are kept on Helm
uninstall. Knative creates runtime-only leader election resources, and Helm can
otherwise hit webhook ordering races while deleting Knative custom resources.

## Kustomize Mapping

- `ci/values-crds.yaml`: CRD-only subset of `common/knative/knative-serving/overlays/gateways`
- `ci/values-platform.yaml`: non-CRD resources from `common/knative/knative-serving/overlays/gateways`; render with `--include-crds` for full Kustomize parity

`knative-eventing`, post-install migration jobs, Ambient mode, Gateway API, and
existing/shared Knative modes are intentionally deferred to later chart slices.

## Regenerate Static Manifests

Run from the repository root:

```bash
kustomize build common/knative/knative-serving/overlays/gateways \
  > /tmp/knative-serving-platform.yaml

python3 - /tmp/knative-serving-platform.yaml \
  experimental/helm/charts/knative-serving/crds/knative-serving.yaml \
  experimental/helm/charts/knative-serving/manifests/platform.yaml <<'PY'
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
helm lint experimental/helm/charts/knative-serving
./tests/helm_kustomize_compare.sh knative-serving crds
./tests/helm_kustomize_compare.sh knative-serving platform
```
