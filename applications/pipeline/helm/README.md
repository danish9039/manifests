# Kubeflow Pipelines Helm Chart

> Draft: credential and data-retention configuration is unresolved; not
> administrator-ready. See [Credentials](#credentials) and
> [Storage and uninstallation](#storage-and-uninstallation).

This chart renders the current Kubeflow Pipelines Kustomize resources with
Helm. Kustomize remains the source of truth. The payloads under `manifests/`
are generated from the two supported platform scenarios, and small templates
load them with `.Files.Get`. Helm does not evaluate that content as a template,
so Go template delimiters inside upstream manifests are emitted literally.

The packaged Kubeflow Pipelines release is the `appVersion` of `Chart.yaml`.
The values of the chart are `scenario`, `crds.enabled`, and `install.enabled`.

## Installation

Install the Kubeflow foundation, cert-manager, Istio, OAuth2-Proxy, Profile
Controller, and required multi-tenancy resources first.

The chart requires its release namespace to be `kubeflow` and refuses to install
anywhere else. Every resource it renders declares `namespace: kubeflow`, so a
release installed elsewhere would store its metadata in one namespace while
modifying another, and `helm uninstall` would then delete resources it does not
appear to own. It does not create that namespace - the `kubeflow-namespaces`
foundation chart does.

Install the CustomResourceDefinitions of the scenario first:

```bash
helm install kubeflow-pipelines ./applications/pipeline/helm \
  --namespace kubeflow \
  --set scenario=platform-database
```

Wait for every CustomResourceDefinition rendered by the selected scenario:

```bash
helm get manifest kubeflow-pipelines --namespace kubeflow |
  awk '
    $0 == "kind: CustomResourceDefinition" {
      custom_resource_definition = 1
      next
    }
    custom_resource_definition && /^  name: / {
      print $2
      custom_resource_definition = 0
    }
  ' |
  while read -r custom_resource_definition_name; do
    kubectl wait --for=condition=Established \
      "crd/${custom_resource_definition_name}" \
      --timeout=120s
  done
```

Upgrade the same release to the complete database scenario:

```bash
helm upgrade kubeflow-pipelines ./applications/pipeline/helm \
  --namespace kubeflow \
  --values ./applications/pipeline/helm/ci/values-platform-database.yaml \
  --wait \
  --timeout 20m
```

For Kubernetes-native pipeline definitions, use
`scenario=platform-k8s-native` during the first command and
`ci/values-platform-k8s-native.yaml` during the upgrade.

`tests/pipelines_helm_install.sh <scenario>` runs the same three steps and then
waits for every Deployment of the release. The scenario argument is required.

## Credentials

The payload ships the baseline default Secrets `mysql-secret` and
`mlpipeline-minio-artifact`, identical to the Kustomize installation. The
credential interface of this chart is unresolved: the chart has no values for
credentials, and no administrator procedure for other credentials is validated.
Equal Helm and Kustomize renders prove the desired output only. They do not
show how Helm treats a Secret that was changed in the cluster, nor that the
database and the artifact service agree with a changed Secret.

## Storage and uninstallation

`helm uninstall` deletes the chart-owned PersistentVolumeClaims
`mysql-pv-claim` and `seaweedfs-pvc`. Whether the backing data is deleted
depends on the reclaim policy of the PersistentVolume and the StorageClass.
The chart gives no data retention guarantee.

The CustomResourceDefinitions carry `helm.sh/resource-policy: keep`, so
`helm uninstall` retains the 16 definitions and therefore the custom resource
objects of those kinds. Database records and stored artifacts are not protected
by that annotation.

## Kustomize Mapping

- `platform-database`: `applications/pipeline/overlays`
- `platform-k8s-native`: `applications/pipeline/upstream/env/cert-manager/platform-agnostic-multi-user-k8s-native`

AWS, Google Cloud, MinIO, PostgreSQL, OpenShift, and standalone installation
variants are intentionally deferred.

## Regeneration

`scripts/synchronize-pipelines-manifests.sh` imports the upstream release,
regenerates the payloads, and updates `appVersion`. To regenerate the payloads
from the local Kustomize inputs only, run from the repository root:

```bash
python3 scripts/generate-pipelines-helm-manifests.py
```

The generator renders both supported Kustomize paths, stores identical
resources once, separates CustomResourceDefinitions from ordinary resources,
and writes scenario-specific differences under `manifests/`.

To verify that the committed payloads are what the generator produces, without
writing anything:

```bash
python3 scripts/generate-pipelines-helm-manifests.py --check
```

It lists every stale, missing, or extra file, prints the command that repairs
it, and exits with status 1.

## Validation

```bash
python3 scripts/generate-pipelines-helm-manifests.py --check
python3 tests/pipelines_helm_manifest_generator_test.py
python3 tests/pipelines_helm_chart_test.py
python3 tests/pipelines_helm_install_helper_test.py
helm lint applications/pipeline/helm --namespace kubeflow
python3 tests/run_helm_kustomize_comparison.py kubeflow-pipelines --all-scenarios
```
