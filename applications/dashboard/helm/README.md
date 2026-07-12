# Kubeflow Dashboard Helm Chart

This chart renders the current Kubeflow Dashboard Kustomize resources with Helm.
The first slice is intentionally static so rendered output stays aligned with
`applications/dashboard`.

## Install

Install the platform prerequisites first: `kubeflow-namespaces`,
`kubeflow-platform`, `cert-manager`, `istio`, `oauth2-proxy`, and `dex`. Store
Helm release metadata in `kubeflow-system`; Dashboard workloads still run in
`kubeflow`.

```bash
helm install kubeflow-dashboard ./applications/dashboard/helm \
  --namespace kubeflow-system \
  --values ./applications/dashboard/helm/ci/values-platform.yaml \
  --wait
```

## Caveats

The current platform Dashboard Kustomize overlay includes Central Dashboard,
PodDefaults webhook, and Profile Controller/KFAM. This chart keeps that grouping
for parity.

The `profiles.kubeflow.org` and `poddefaults.kubeflow.org` CRDs are rendered
from templates in this first parity slice. Treat CRD lifecycle as a maintenance
caveat before making this chart a long-term supported install surface.

## Kustomize Mapping

- `ci/values-platform.yaml`: `applications/dashboard/overlays/istio`

## Comparison

```bash
helm lint applications/dashboard/helm
./tests/helm_kustomize_compare.sh kubeflow-dashboard platform
./tests/helm_kustomize_compare_all.sh kubeflow-dashboard
```
