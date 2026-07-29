# Kubeflow Dashboard Helm Chart

This chart renders the current Kubeflow Dashboard Kustomize resources with Helm.
Kustomize remains the source of truth. The synchronization script builds the
platform overlay once and writes deterministic payloads under `manifests/`, which
small templates load with `.Files.Get`. Helm does not evaluate that content as a
template, so Go template delimiters inside upstream manifests are emitted
literally.

The resources that carry a value Kustomize already declares - the three
Deployments and the four ConfigMaps - are rendered from hand-written templates
instead, so those values can be set through `values.yaml`. Everything else is
vendored verbatim. Before committing an update, the synchronization script runs
Helm linting and the Helm/Kustomize parity comparison.

## Install

Install the platform prerequisites first: `kubeflow-namespaces`,
`kubeflow-platform`, `cert-manager`, `istio`, `oauth2-proxy`, and `dex`.

The chart requires its release namespace to be `kubeflow` and refuses to install
anywhere else. It does not create or own that namespace - the
`kubeflow-namespaces` foundation chart does. Every resource this chart renders
declares `namespace: kubeflow`, so a release installed elsewhere would store its
metadata in one namespace while modifying another, and `helm uninstall` would
then delete resources it does not appear to own.

```bash
helm install kubeflow-dashboard ./applications/dashboard/helm \
  --namespace kubeflow \
  --wait
```

## Configuration

Every value corresponds to something the Kustomize baseline already declares -
an `images:` transformer or a `configMapGenerator` input - and every default
equals the value rendered by `applications/dashboard/overlays/istio`.

| Value | Default | Purpose |
| --- | --- | --- |
| `image.registry` | `ghcr.io/kubeflow/dashboard` | Registry prefix for all four images. Set this to install from a mirror or an air-gapped registry. |
| `image.tag` | chart `appVersion` | Tag shared by all four images. |
| `centralDashboard.image.repository` | `dashboard` | Central Dashboard repository. |
| `profileController.image.repository` | `profile-controller` | Profile Controller repository. |
| `profileController.accessManagement.image.repository` | `access-management` | Access Management repository. |
| `podDefaultsWebhook.image.repository` | `poddefaults-webhook` | PodDefaults webhook repository. |
| `identity.userIdHeader` | `kubeflow-userid` | Request header carrying the user identity. |
| `identity.userIdPrefix` | empty | Prefix stripped from that header. |
| `centralDashboard.registrationFlow` | `false` | Self-service user registration. |
| `centralDashboard.collectMetrics` | `true` | Anonymous usage metrics. |
| `centralDashboard.links` | inherited | Menu, quick link and documentation definitions, as JSON. |
| `centralDashboard.settings` | inherited | Central Dashboard runtime settings, as JSON. |
| `profileController.admin` | empty | Cluster administrator granted access to every Profile. |
| `profileController.workloadIdentity` | empty | Google Cloud workload identity for Profile service accounts. |
| `profileController.namespaceLabels` | inherited | Labels applied to every Profile namespace, as YAML. |
| `customResourceDefinitions.enabled` | `true` | Render the PodDefault and Profile custom resource definitions. |

The three document values - `links`, `settings` and `namespaceLabels` - are
**strings** containing a whole document. Passing a map or list is rejected,
because Helm would otherwise write Go's own formatting of that value and the
application could not parse it. Leave a document empty to inherit the upstream
default byte for byte, or supply the replacement as a quoted block scalar.

`identity.userIdHeader` and `identity.userIdPrefix` are consumed by both the
Central Dashboard and the Profile Controller. They are declared once and rendered
into both ConfigMaps so the two cannot disagree.

The three values ending in `Principal` are platform wiring rather than ordinary
settings. They are the service account identities that Kubeflow components
authenticate with when calling the Profile Controller. Changing one without also
changing the corresponding component's namespace or service account breaks
authorization.

A value left empty for `links`, `settings` or `namespaceLabels` inherits the
upstream document from `manifests/documents/` byte for byte. Set it to replace
the document entirely.

Changing any value that feeds a ConfigMap updates a checksum annotation on the
consuming Deployment, so `helm upgrade` restarts the workload. Kustomize achieves
the same result through content-hashed ConfigMap names.

## Caveats

The platform Dashboard Kustomize overlay includes Central Dashboard, the
PodDefaults webhook, and Profile Controller with KFAM. This chart keeps that
grouping for parity.

### Custom resource definition lifecycle

The `profiles.kubeflow.org` and `poddefaults.kubeflow.org` custom resource
definitions are rendered from `templates/` and carry
`helm.sh/resource-policy: keep`. This deviates from Helm's documented
recommendation to place custom resource definitions in `crds/`, deliberately:
Helm never upgrades or deletes anything in `crds/`, which would freeze both
schemas at their first installed version. Rendering them as templates keeps the
schemas upgradeable, while the retention policy stops `helm uninstall` from
deleting every Profile and PodDefault in the cluster.

Because they are templates rather than `crds/` content, Helm's `--skip-crds`
option has no effect on them. Use `customResourceDefinitions.enabled=false` when
an administrator or another release already owns both definitions.

| Operation | Behaviour |
| --- | --- |
| `helm install` | Creates both definitions unless `customResourceDefinitions.enabled=false`. |
| `helm upgrade` | Applies schema changes from the new chart version. |
| `helm uninstall` | **Retains** both definitions and every Profile and PodDefault. Namespaced Dashboard resources are removed. |
| reinstall | Succeeds against the retained definitions and adopts them into the new release. |
| manual cleanup | `kubectl delete crd profiles.kubeflow.org poddefaults.kubeflow.org` — this deletes every Profile and PodDefault in the cluster. |

Regenerate the payloads through the component synchronization workflow:

```bash
python3 -m pip install pyyaml "ruamel.yaml==0.19.1"
KUBEFLOW_SYNCHRONIZE_NO_COMMIT=true \
  ./scripts/synchronize-dashboard-manifests.sh
```

Do not edit files under `manifests/` directly.

Review a generated payload change in two steps, because they prove different
things. First read the change by resource identity and upstream source boundary:
which resources appeared, disappeared or changed, and does each change belong to
the upstream release. Then regenerate and confirm `git diff` is empty. The replay
proves only that the generator is deterministic; it cannot tell you whether a new
upstream release introduced an unintended webhook, permission or policy change.

## Kustomize Mapping

- `ci/values-platform.yaml`: `applications/dashboard/overlays/istio`

## Comparison

```bash
helm lint applications/dashboard/helm --namespace kubeflow
./tests/helm_kustomize_compare.sh kubeflow-dashboard platform
./tests/helm_kustomize_compare_all.sh kubeflow-dashboard
python3 tests/test_dashboard_helm_chart.py
python3 tests/test_generate_dashboard_helm_manifests.py
```
