# Kubeflow Pipelines Helm Chart

This chart renders the current Kubeflow Pipelines Kustomize resources with Helm.
The first slice is intentionally static so rendered output stays aligned with
`applications/pipeline`.

## Install

Install the platform foundation and wrapper charts first. Store Helm release
metadata in `kubeflow-system`; KFP workloads still run in `kubeflow`.

Install CRDs first, then upgrade to the full platform resources:

```bash
helm install kubeflow-pipelines ./experimental/helm/charts/kubeflow-pipelines \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/kubeflow-pipelines/ci/values-crds-database.yaml \
  --wait

helm upgrade kubeflow-pipelines ./experimental/helm/charts/kubeflow-pipelines \
  --namespace kubeflow-system \
  --values ./experimental/helm/charts/kubeflow-pipelines/ci/values-platform-database.yaml \
  --wait
```

For Kubernetes-native pipeline definitions, use the matching `k8s-native`
values files for both steps.

## Caveats

Only platform mode is supported in this first slice. Standalone mode, cloud
overlays, Postgres, OpenShift, and broad image/security-context customization
are intentionally deferred.

KFP components are rendered into the same `kubeflow` namespace to match the
current Kustomize install path.

## Kustomize Mapping

- `ci/values-platform-database.yaml`: `applications/pipeline/overlays`
- `ci/values-platform-k8s-native.yaml`: `applications/pipeline/upstream/env/cert-manager/platform-agnostic-multi-user-k8s-native`

## Comparison

```bash
helm lint experimental/helm/charts/kubeflow-pipelines
./tests/helm_kustomize_compare.sh kubeflow-pipelines platform-database
./tests/helm_kustomize_compare.sh kubeflow-pipelines platform-k8s-native
./tests/helm_kustomize_compare_all.sh kubeflow-pipelines
```
