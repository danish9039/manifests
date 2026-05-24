# Katib Helm Chart

A Helm chart for deploying [Katib](https://github.com/kubeflow/katib) - AutoML on Kubernetes.

## Description

Katib is a Kubernetes-native project for automated machine learning (AutoML). Katib supports hyperparameter tuning, early stopping, and neural architecture search (NAS).

## Kubeflow Platform Install

The Kubeflow platform profile maps to the current Kustomize install path:

```text
applications/katib/upstream/installs/katib-with-kubeflow
```

Install the foundation charts, cert-manager, and Istio first. Then install
Katib with the Kubeflow platform values:

```bash
helm install katib ./experimental/helm/charts/katib \
  --namespace kubeflow \
  --values ./experimental/helm/charts/katib/ci/values-kubeflow.yaml \
  --wait
```

For the platform profile, Helm release metadata is stored in `kubeflow`, and
Katib workloads also run in `kubeflow`.

The platform profile creates Katib `Certificate` and `Issuer` resources, but it
does not install cert-manager itself. Install the Kubeflow cert-manager wrapper
before installing Katib.

## Kustomize Mapping

The chart keeps compatibility with the current Katib Kustomize install
profiles:

| Helm scenario | Kustomize baseline |
| --- | --- |
| `standalone` | `applications/katib/upstream/installs/katib-standalone` |
| `cert-manager` | `applications/katib/upstream/installs/katib-cert-manager` |
| `external-db` | `applications/katib/upstream/installs/katib-external-db` |
| `leader-election` | `applications/katib/upstream/installs/katib-leader-election` |
| `openshift` | `applications/katib/upstream/installs/katib-openshift` |
| `standalone-postgres` | `applications/katib/upstream/installs/katib-standalone-postgres` |
| `with-kubeflow` / `platform` | `applications/katib/upstream/installs/katib-with-kubeflow` |

`platform` is a Project 5 naming alias for the existing `with-kubeflow`
profile. The existing `with-kubeflow` comparison scenario remains supported.

## Comparison

```bash
helm lint experimental/helm/charts/katib
./tests/helm_kustomize_compare.sh katib platform
./tests/helm_kustomize_compare.sh katib with-kubeflow
./tests/helm_kustomize_compare_all.sh katib
```

Standalone namespace/release behavior, enterprise values, and broader
production hardening remain follow-up design topics.
