# KServe Models Web App Helm Chart

This Helm chart deploys the KServe Models Web App.

## Description

The KServe Models Web App is the Kubeflow UI companion for KServe model serving
endpoints. It lists and manages KServe resources through the Kubeflow platform
and routes through Istio in the Kubeflow overlay.

## Kustomize Mapping

This chart is an experimental Helm equivalent for the current Kustomize paths:

```text
applications/kserve/models-web-app/base
applications/kserve/models-web-app/overlays/kubeflow
```

The `base` scenario renders resources into the `kserve` namespace. The
`kubeflow` scenario renders the Kubeflow-integrated application into the
`kubeflow` namespace with Istio routing and authorization resources.

## Install Contract

Standalone/base-style render:

```bash
helm install kserve-models-web-application \
  ./experimental/helm/charts/kserve-models-web-app \
  --namespace kserve \
  --values ./experimental/helm/charts/kserve-models-web-app/ci/base-values.yaml
```

Kubeflow platform render:

```bash
helm install kserve-models-web-application \
  ./experimental/helm/charts/kserve-models-web-app \
  --namespace kubeflow \
  --values ./experimental/helm/charts/kserve-models-web-app/ci/kubeflow-values.yaml
```

For Project 5, keep the chart aligned with the current Kustomize output first.
Do not bump image tags or synchronized manifests in this chart alignment slice.

## Current Scope

Supported Helm/Kustomize comparison scenarios:

| Scenario | Kustomize path | Namespace |
| --- | --- | --- |
| `base` | `applications/kserve/models-web-app/base` | `kserve` |
| `kubeflow` | `applications/kserve/models-web-app/overlays/kubeflow` | `kubeflow` |

The chart assumes KServe, Istio, and Kubeflow platform resources are installed
before the Kubeflow overlay is used. Release and synchronization work for newer
KServe Models Web App manifests is tracked separately and should not be folded
into this documentation alignment.
