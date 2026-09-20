# Kubeflow Workspaces Helm Chart

> **DANGER: Workspaces (Notebooks v2) is still pre-GA.**
>
> **DO NOT DEPLOY THIS TO A PRODUCTION CLUSTER.**
>
> See this for the current status:
> <https://www.kubeflow.org/docs/components/notebooks/notebooks-v2-pre-ga-banner>

This chart renders the Kubeflow Workspaces Kustomize resources
(`applications/workspaces/overlays/istio`: controller, backend and frontend)
with Helm. Kustomize remains the source of truth. `kubeflow/notebooks` publishes
no Helm chart for Workspaces, so this is a generated payload chart, not a
wrapper: the synchronization script builds the overlay once and writes
deterministic payloads under `manifests/`, which two small templates load with
`.Files.Get`.

Helm does not send `.Files.Get` content through the template renderer, so Go
template delimiters that upstream manifests legitimately contain are emitted
literally. The WorkspaceKind definition already documents expressions such as
`{{ httpPathPrefix 'jupyterlab' }}`; evaluating them as chart code would fail
the render.

## Prerequisites

Install these first, in this order:

1. The platform foundation charts, which create the `kubeflow` namespace
   (`common/kubeflow-namespace/helm`) and the Kubeflow roles.
2. cert-manager, ready to issue certificates. The chart renders an `Issuer` and
   a `Certificate` for the validating webhook, and cert-manager injects the
   certificate authority bundle into the webhook configuration and into both
   definitions.
3. Istio. The chart renders `VirtualService`, `DestinationRule` and
   `AuthorizationPolicy` objects, and the namespace it creates is labelled
   `istio-injection: enabled`.

The Workspaces menu entry of the Central Dashboard
(`applications/workspaces/components/centraldashboard`) is not part of this
chart.

## Install

```bash
helm install kubeflow-workspaces applications/workspaces/helm \
  --namespace kubeflow \
  --values applications/workspaces/helm/ci/values-istio.yaml \
  --wait --timeout 5m
```

This is one revision. The payload contains no custom resource of the chart's own
kinds, so there is no two-phase installation.

The release is listed in `kubeflow`, not in `kubeflow-workspaces`:

```bash
helm list -n kubeflow
```

## Release Namespace And Workload Namespace

Other Kubeflow charts install into the namespace that holds their workloads.
This chart deliberately deviates from that rule:

- The **release record** is stored in `kubeflow`. `templates/validate-namespace.yaml`
  refuses every other release namespace, including `kubeflow-workspaces`.
- The chart **owns** `Namespace/kubeflow-workspaces`, with the labels of the
  Kustomize baseline (`istio-injection: enabled`,
  `pod-security.kubernetes.io/enforce: restricted`,
  `app.kubernetes.io/part-of: kubeflow-workspaces`). Every namespaced object in
  the payload declares `namespace: kubeflow-workspaces` explicitly, so nothing
  falls back to the release namespace.

The reason is that a release stored inside `kubeflow-workspaces` would keep its
record in a namespace that the same release creates and deletes. Storing it in
`kubeflow`, which exists before this chart, keeps the record outside that
namespace. The `kubeflow-namespaces` foundation chart sets the precedent: its
release is stored in one namespace while it renders others. Do not use
`--create-namespace`; it is neither an ownership nor an adoption mechanism.

## Namespace Contract

| Situation | Behavior |
| --- | --- |
| Fresh platform installation | The only supported path. |
| `kubeflow-workspaces` already exists and is not owned by this release, for example from a Kustomize installation | The installation is expected to be refused by Helm's ownership check. The chart offers no `--take-ownership` recipe and no silent adoption. Migrating a Kustomize installation is out of scope. |
| `helm uninstall` | The `kubeflow-workspaces` namespace is **deleted, together with everything inside it, including objects that this release does not own**. Do not keep anything of your own in this namespace. |
| What remains after `helm uninstall` | The two definitions (`helm.sh/resource-policy: keep`), every `Workspace` with its PersistentVolumeClaim in the profile namespaces, and every cluster-scoped `WorkspaceKind`. |
| Reinstallation | Only after the namespace has finished terminating. The same release name and release namespace adopt the kept definitions again. |

The namespace is deleted on purpose. `kubeflow-workspaces` is a dedicated system
namespace for the controller, the backend and the frontend. User data lives
elsewhere: `Workspace` objects and their PersistentVolumeClaims are in the
profile namespaces, and `WorkspaceKind` is cluster-scoped. Deleting the
namespace matches what removing the Kustomize component does, and a kept
namespace would stay behind with its Istio injection and Pod Security labels
and no owner.

Retained objects do **not** mean that the Workspaces API stays usable. After
`helm uninstall` the controller and the validating webhook are gone: nothing
reconciles a `Workspace`, and admission is no longer validated because the
webhook configuration was deleted with the release. Treat the time between
uninstall and reinstall as an outage of Workspaces, not as a degraded mode.
A `WorkspaceKind` that is in use carries the
`notebooks.kubeflow.org/workspacekind-protection` finalizer, which only the
controller removes, so deleting one during that time blocks until the chart is
installed again.

Wait for the namespace to terminate before installing again:

```bash
helm uninstall kubeflow-workspaces --namespace kubeflow --wait
kubectl wait --for=delete namespace/kubeflow-workspaces --timeout=300s
```

## Configuration

| Value | Default | Purpose |
| --- | --- | --- |
| `scenario` | `istio` | Rendered Kustomize parity scenario. Only `istio` is supported. |
| `customResourceDefinitions.enabled` | `true` | Render the Workspace and WorkspaceKind custom resource definitions. |

There is deliberately no switch for an externally managed namespace; that is
not a supported scenario. Values that the Kustomize baseline declares, such as
container images, are **not** exposed. Adding them means rendering the
resources that carry them from hand-written templates, which is a separate
change.

## Definitions And Webhooks

`workspacekinds.kubeflow.org` (cluster-scoped) and `workspaces.kubeflow.org`
(namespaced) are rendered from `templates/` and carry
`helm.sh/resource-policy: keep`. This deviates from Helm's documented
recommendation to place custom resource definitions in `crds/`, deliberately:
Helm never upgrades or deletes anything in `crds/`, which would freeze both
schemas at their first installed version while upstream publishes a new beta
about every two weeks. Rendering them as templates keeps the schemas
upgradeable, while the retention policy stops `helm uninstall` from deleting
existing Workspaces and WorkspaceKinds.

Because they are templates rather than `crds/` content, Helm's `--skip-crds`
option has no effect on them. Use `customResourceDefinitions.enabled=false` when
an administrator or another release already owns them.

In this version (`v2.0.0-beta.2`) neither definition declares a conversion
webhook: each serves the single version `v1beta1`, and the upstream conversion
patch is commented out. Both definitions do carry the
`cert-manager.io/inject-ca-from` annotation. `tests/workspaces_helm_chart_test.py`
fails when a later synchronization introduces a conversion webhook, because the
uninstall contract above would then need to be revisited: retained definitions
would point at a webhook service that no longer exists.

The chart does render a `ValidatingWebhookConfiguration` with failure policy
`Fail` for `Workspace` (create, update) and `WorkspaceKind` (create, update,
delete). It is served by the controller through `workspaces-webhook-service`
with a certificate that cert-manager issues into `kubeflow-workspaces`.

## Kustomize Mapping

- `ci/values-istio.yaml`: `applications/workspaces/overlays/istio`

`kustomize/kustomization.yaml` is the generator input: that overlay plus one
patch that adds `helm.sh/resource-policy: keep` to every definition. The
content-hashed ConfigMap name is kept exactly as Kustomize renders it.

## Comparison

```bash
helm lint applications/workspaces/helm --namespace kubeflow
python3 tests/run_helm_kustomize_comparison.py kubeflow-workspaces istio
python3 tests/run_helm_kustomize_comparison.py kubeflow-workspaces --all-scenarios
python3 tests/workspaces_helm_chart_test.py
```

How this chart is compared, including the retained definitions, is in
[`ci/comparison.yaml`](ci/comparison.yaml); the descriptor format is documented in
[`tests/README.md`](../../../tests/README.md). The `Namespace` object is part of
the comparison.

`tests/workspaces_helm_install.sh` installs the chart on a cluster.
`tests/workspaces_helm_lifecycle_test.sh` exercises explicit `Workspace`
deletion, uninstall with a retained `Workspace`, reinstallation and the refusal
of a namespace that the release does not own; it is destructive and is not part
of a workflow.

## Keeping The Chart Up To Date

Regenerate the payloads from the local Kustomize inputs, or verify them
without writing:

```bash
python3 -m pip install pyyaml "ruamel.yaml==0.19.1"
python3 scripts/generate-workspaces-helm-manifests.py
python3 scripts/generate-workspaces-helm-manifests.py --check
```

Import a new upstream release through the component synchronization script. It
updates `appVersion` in `Chart.yaml`, regenerates the payloads and lints the
chart:

```bash
KUBEFLOW_SYNCHRONIZE_NO_COMMIT=true \
  ./scripts/synchronize-kubeflow-workspaces-manifests.sh
```

Do not edit files under `manifests/` directly. Review a generated payload change
by resource identity and upstream source boundary first, then regenerate and
confirm `git diff` is empty. The replay proves the generator is deterministic; it
cannot tell you whether a new upstream release introduced an unintended webhook,
permission or policy change.
