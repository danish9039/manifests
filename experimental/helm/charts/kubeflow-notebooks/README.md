# Kubeflow Notebooks Helm Chart

This chart renders the current Kubeflow Notebooks v1 Kustomize resources with
Helm. The first slice is intentionally static so rendered output stays aligned
with `applications/notebooks-v1`.

## Install

Install the platform foundation and wrapper charts first. Store Helm release
metadata in `kubeflow-system`; Notebooks v1 workloads still run in `kubeflow`.

```bash
helm install kubeflow-notebooks ./experimental/helm/charts/kubeflow-notebooks \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/kubeflow-notebooks/ci/values-platform.yaml \
  --wait
```

## Caveats

The current platform Notebooks v1 Kustomize overlay includes Jupyter Web App,
Notebook Controller, PVC Viewer Controller, Volumes Web App, Tensorboard
Controller, and Tensorboards Web App. This chart keeps that grouping for parity.

The `notebooks.kubeflow.org`, `pvcviewers.kubeflow.org`, and
`tensorboards.tensorboard.kubeflow.org` CRDs are rendered from templates in this
first parity slice. Treat CRD lifecycle as a maintenance caveat before making
this chart a long-term supported install surface.

## Kustomize Mapping

- `ci/values-platform.yaml`: `applications/notebooks-v1/overlays/istio`

## Comparison

```bash
helm lint experimental/helm/charts/kubeflow-notebooks
./tests/helm_kustomize_compare.sh kubeflow-notebooks platform
./tests/helm_kustomize_compare_all.sh kubeflow-notebooks
```
