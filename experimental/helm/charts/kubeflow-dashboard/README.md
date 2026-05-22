# Kubeflow Dashboard Helm Chart

This chart renders the current Kubeflow Dashboard Kustomize resources with Helm.
The first slice is intentionally static so rendered output stays aligned with
`applications/dashboard`.

## Install

Install the platform foundation and wrapper charts first. Store Helm release
metadata in `kubeflow-system`; Dashboard workloads still run in `kubeflow`.

```bash
helm install kubeflow-dashboard ./experimental/helm/charts/kubeflow-dashboard \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/kubeflow-dashboard/ci/values-platform.yaml \
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

- `ci/values-centraldashboard-base.yaml`: `applications/dashboard/upstream/centraldashboard/base`
- `ci/values-centraldashboard-istio.yaml`: `applications/dashboard/upstream/centraldashboard/overlays/istio`
- `ci/values-centraldashboard-kserve.yaml`: `applications/dashboard/upstream/centraldashboard/overlays/kserve`
- `ci/values-poddefaults-cert-manager.yaml`: `applications/dashboard/upstream/poddefaults-webhooks/overlays/cert-manager`
- `ci/values-profile-kubeflow-pss.yaml`: `applications/dashboard/upstream/profile-controller/overlays/kubeflow-pss`
- `ci/values-platform.yaml`: `applications/dashboard/overlays/istio`

## Comparison

```bash
helm lint experimental/helm/charts/kubeflow-dashboard
./tests/helm_kustomize_compare.sh kubeflow-dashboard platform
./tests/helm_kustomize_compare_all.sh kubeflow-dashboard
```
