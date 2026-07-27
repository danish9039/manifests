# Kubeflow Dashboard Helm Chart

This chart renders the current Kubeflow Dashboard Kustomize resources with Helm.
Kustomize remains the source of truth: the synchronization script builds the
complete platform overlay once, validates every resource against an explicit
component classification, and writes deterministic payloads under `manifests/`.
Small templates load those payloads without evaluating their contents as Helm
templates. Before committing an update, the synchronization script runs Helm
linting and the complete Helm/Kustomize parity comparison.

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

Helm retains the `profiles.kubeflow.org` and `poddefaults.kubeflow.org` custom
resource definitions on uninstall so deleting a release does not delete their
custom resources. Schema changes must be synchronized into the generated
payloads and applied through a chart upgrade.

Regenerate the payloads through the component synchronization workflow:

```bash
python3 -m pip install pyyaml "ruamel.yaml==0.19.1"
KUBEFLOW_SYNCHRONIZE_NO_COMMIT=true \
  ./scripts/synchronize-dashboard-manifests.sh
```

Do not edit files under `manifests/` directly.

## Kustomize Mapping

- `ci/values-platform.yaml`: `applications/dashboard/overlays/istio`

## Comparison

```bash
helm lint applications/dashboard/helm
./tests/helm_kustomize_compare.sh kubeflow-dashboard platform
./tests/helm_kustomize_compare_all.sh kubeflow-dashboard
```
