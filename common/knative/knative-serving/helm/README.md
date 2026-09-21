# Knative Serving for Kubeflow

This chart installs the distribution's patched Serving and net-istio v1.23.0
bundles. It does not install the Knative Operator. The `platform` default equals
`kustomize build common/knative/knative-serving/overlays/gateways`, except for
Helm retention annotations. Most resources are generated literal payloads; the
Namespace and two bootstrap consumers are small parity-checked templates.

## Prerequisites and installation

Use Helm 4.2.2. Install the Kubeflow namespace, Certificate Manager, Istio,
cluster-local gateway, and Kubeflow Istio resources first. The Istio release owns
those gateways. Run all commands from the distribution repository root:

```sh
./tests/knative_serving_helm_install.sh
```

The Helm release `knative-serving` stores its history in `kubeflow`. This chart
owns the `knative-serving` Namespace, preserves its distribution labels, and
retains it on uninstall. Installing the release in another namespace fails.
Namespace retention avoids destroying any objects an administrator added there.

The installer uses one release with three explicit phases:

1. `installation.phase=definitions`: Namespace and 12 retained CRDs; wait for
   their `Established` condition.
2. `installation.phase=controllers`: add controllers, services, admission
   configurations and networking; wait for the webhook Deployments.
3. `installation.phase=complete` (default): add the queue-proxy Image and internal
   routing Certificate after their APIs and admission controllers are available.

These phases are bootstrap mechanics, not selectable product installations.
Never set a running release back to `definitions` or `controllers`: Helm would
remove previously rendered resources. Existing complete releases use a direct complete upgrade. The installer reads
the saved phase and resumes interrupted bootstrap forward, with explicit reset
values on each upgrade; it never infers readiness merely from release existence.
Unknown saved phases fail for operator inspection.

There is no generic patch interface. The queue-proxy digest is synchronized from
upstream into chart metadata, and must equal the generated `config-deployment`
image. It is not a separate administrator override. Changing distribution
configuration requires a source overlay change followed by regeneration and
parity tests.

## Upgrade, rollback and removal

```sh
helm upgrade knative-serving common/knative/knative-serving/helm -n kubeflow --reset-values --set installation.phase=complete --wait --timeout 10m
helm history knative-serving -n kubeflow
# Choose a previously complete revision at a compatible Knative version.
helm rollback knative-serving COMPLETE_REVISION -n kubeflow --wait --timeout 10m
helm uninstall knative-serving -n kubeflow --wait --timeout 10m
```

Definitions are rendered through templates with `helm.sh/resource-policy: keep`,
so upgrades can update schemas while uninstall leaves definitions and user
objects. The component Namespace is retained too. Controllers, webhooks, routes
and availability are not retained. Removal interrupts reconciliation and serving;
retention is not a zero-downtime or backup guarantee. Reinstall using the same
release name and release namespace. Existing ownership metadata is not adopted
from an unrelated release or Kustomize installation automatically.

Only rollback to a **complete**, schema-compatible revision. Bootstrap revisions
omit controllers or consumers and are not operational rollback targets. Never
use routine `--force-conflicts`; investigate the field owner. CRD/schema downgrade
and existing workload recovery require lifecycle evidence before release approval.

The separately synchronized storage-version migration Job remains an explicit
administrator step after a supported version upgrade and healthy controllers:

```sh
kubectl delete job storage-version-migration-serving -n knative-serving --ignore-not-found
kubectl apply -k common/knative/knative-serving-post-install-jobs/base
kubectl wait --for=condition=complete job/storage-version-migration-serving -n knative-serving --timeout=10m
```

The Job has a fixed name and a 600-second TTL. Delete its previous completed Job
before deliberately rerunning it. It is not an install/uninstall hook. Check
Knative's version-specific upgrade guidance before changing stored API versions.

## Validation and draft boundaries

```sh
python3 scripts/generate-knative-serving-helm-manifests.py --check
helm lint common/knative/knative-serving/helm -n kubeflow
python3 tests/run_helm_kustomize_comparison.py knative-serving --all-scenarios
python3 tests/knative_serving_helm_chart_test.py
python3 tests/helm_release_size.py knative-serving
./tests/knative_serving_helm_smoke_test.sh kubeflow-user-example-com
# Destructive; use only a disposable test cluster. Requires PyYAML.
./tests/knative_serving_helm_lifecycle_test.sh kubeflow-user-example-com
```

The Helm integration workflow installs this chart and tests a real Knative Service
through the cluster-local gateway, requiring its exact response body and rejecting
an unauthenticated request. Existing KServe tests remain in that workflow.
The lifecycle gate keeps the Service identity through an unchanged upgrade, a
disposable controller Pod-template change, rollback, uninstall and reinstall.
That changed-rollout fixture is not evidence for cross-version schema downgrade.
Local chart tests and parity do not prove live installation. Before promoting the
draft, record clean installation, unchanged upgrade, a compatible changed
configuration upgrade and rollback, a retained user Service across uninstall and
same-name reinstall, recovered route traffic and healthy webhook certificates.
No cluster lifecycle result is claimed by the chart implementation alone.

Synchronization downloads the pinned bundles, updates chart metadata, regenerates
payloads, and lints the chart. It stages only generated component outputs.
Regenerate local overlay changes without downloading or committing:

```sh
python3 scripts/generate-knative-serving-helm-manifests.py
```
