# Katib Helm Chart

A Helm chart for deploying [Katib](https://github.com/kubeflow/katib) - AutoML on Kubernetes.

## Description

Katib is a Kubernetes-native project for automated machine learning (AutoML). Katib supports hyperparameter tuning, early stopping, and neural architecture search (NAS).

## Status

This chart is a relocation draft.

The hand-written chart moved from `experimental/helm/charts/katib` to
`applications/katib/helm`, next to its Kustomize component. The chart name, the
release name `katib`, the namespace `kubeflow`, the templates, the values keys
and the definitions in `crds/` are unchanged apart from the one field named
below, and every values file renders the same resources from both paths. The
chart at the old path was experimental, so this chart neither documents nor
tests an upgrade of a release that was installed from the old path.

The template of the aggregated ClusterRole `kubeflow-katib-admin` no longer
ships `rules`, which the aggregation controller owns, because an unchanged
`helm upgrade` of this chart failed on that role with
`conflict with "clusterrole-aggregation-controller": .rules` while the template
shipped `rules: []` (observed 2026-09-21, Helm 4.2.2, Kubernetes 1.36.1); a
`helm upgrade` after this change is **not yet verified** on a cluster.

## Prerequisites

- Helm 4 and a Kubernetes cluster with a default StorageClass. The bundled MySQL
  database requests a 10Gi PersistentVolumeClaim and the bundled PostgreSQL
  database a 3Gi PersistentVolumeClaim.
- The `kubeflow` namespace for the `with-kubeflow` scenario, which does not
  render it (`namespaceCreate.enabled: false`); the
  `common/kubeflow-namespace/helm` chart creates it. The other scenarios render
  a `Namespace` resource named `kubeflow`, as their Kustomize overlays do.
- cert-manager for the `cert-manager` and `with-kubeflow` scenarios. They render
  a `Certificate` and an `Issuer`, and they do not install cert-manager.
- Istio with the `kubeflow-gateway` Gateway, and the Kubeflow roles, for the
  `with-kubeflow` scenario. It renders a `VirtualService`, an
  `AuthorizationPolicy` and ClusterRoles that aggregate into the Kubeflow roles.

## Installation order

For the platform scenario, install the charts in the order that
`.github/workflows/helm_kubeflow_integration_test.yaml` uses:

1. `common/kubeflow-namespace/helm`
2. `common/cert-manager/helm`
3. `common/istio/helm`, including the Kubeflow Istio resources
4. `common/kubeflow-roles/helm`
5. `applications/katib/helm`

## Scenarios

Each scenario is compared with its Kustomize overlay in continuous integration.

| Scenario | Kustomize overlay | Values file |
| --- | --- | --- |
| `cert-manager` | `applications/katib/upstream/installs/katib-cert-manager` | `ci/values-cert-manager.yaml` |
| `external-db` | `applications/katib/upstream/installs/katib-external-db` | `ci/values-external-db.yaml` |
| `leader-election` | `applications/katib/upstream/installs/katib-leader-election` | `ci/values-leader-election.yaml` |
| `openshift` | `applications/katib/upstream/installs/katib-openshift` | `ci/values-openshift.yaml` |
| `standalone` | `applications/katib/upstream/installs/katib-standalone` | `ci/values-standalone.yaml` |
| `standalone-postgres` | `applications/katib/upstream/installs/katib-standalone-postgres` | `ci/values-postgres.yaml` |
| `with-kubeflow` | `applications/katib/upstream/installs/katib-with-kubeflow` | `ci/values-kubeflow.yaml` |

`ci/values-enterprise.yaml` and `ci/values-production.yaml` belong to no
scenario and have no Kustomize overlay. They are candidates for an explicit
deprecation decision. Until that decision, `tests/katib_helm_chart_test.py`
only verifies that both files render.

## Install

The platform scenario, from the repository root:

```bash
helm install katib applications/katib/helm --namespace kubeflow \
  --values applications/katib/helm/ci/values-kubeflow.yaml \
  --wait --timeout 5m
```

## CustomResourceDefinitions

The `experiments`, `suggestions` and `trials` CustomResourceDefinitions are in
`crds/`. Helm 4.2.2 handles them as follows:

- On `helm install`,
  [`installCRDs`](https://github.com/helm/helm/blob/v4.2.2/pkg/action/install.go#L185)
  sends a server-side apply `PATCH` for every definition in `crds/` with
  `fieldManager=helm` and `force=false`, and no `GET` precedes it. A later
  installation can therefore reapply the bundled definitions.
- An ordinary `helm upgrade` of an existing release does not touch the
  definitions in `crds/`.
- `helm uninstall` does not delete them.

When a Katib release changes a schema, the definitions of the chart version
that is about to be installed have to be applied before `helm upgrade`.

Observed with Helm 4.2.2 on Kubernetes 1.36.1, on definitions that
`helm install` created from `crds/`, with the command
`helm show crds applications/katib/helm | kubectl apply --server-side -f -`:

- With unchanged definitions the command succeeds. `kubectl` becomes a second
  field manager of the three definitions, next to `helm`.
- With a changed definition the command fails for that definition and leaves it
  unchanged. Helm 4 creates the definitions with server-side apply, so the field
  manager `helm` owns `.spec.versions`. One added `additionalPrinterColumns`
  entry in the `trials` definition produced:

  ```text
  error: Apply failed with 1 conflict: conflict with "helm": .spec.versions
  ```

### Updating a changed definition

**UNVERIFIED.** This procedure has not run on a cluster. It stays unverified
until a cluster test has covered a small compatible changed definition, the
handover to the named field manager and a reinstallation with `--skip-crds`.

1. Take the definitions, and nothing else, from the pinned target chart, and
   check that the file holds only the three intended definitions:

   ```bash
   helm show crds applications/katib/helm > target-crds.yaml
   grep "^kind:\|^  name:" target-crds.yaml
   ```

   The expected output is `kind: CustomResourceDefinition` three times, each
   followed by one of `experiments.kubeflow.org`, `suggestions.kubeflow.org` and
   `trials.kubeflow.org`. Schema compatibility, storage version compatibility
   and any data migration are separate prerequisites. Forcing ownership does
   not perform them.
2. Use one stable field manager for this work, exactly
   `kubeflow-crd-maintenance`. Start with a server dry run without force:

   ```bash
   kubectl apply --server-side --field-manager=kubeflow-crd-maintenance \
     --dry-run=server -f target-crds.yaml
   ```

   If it passes, run the same command without `--dry-run=server`, skip step 3
   and continue with step 4. The real apply needs no force in that case.

   If it reports a conflict, inspect the conflicting fields and their owners:

   ```bash
   kubectl get crd <name> -o yaml --show-managed-fields
   ```

   A conflict with `helm` on `.spec.versions` is the result recorded above for
   a changed definition. Stop on unexpected controller-owned or externally
   managed fields.
3. Only after that review, and only for this definitions-only file, run the
   forced dry run and then the forced apply:

   ```bash
   kubectl apply --server-side --field-manager=kubeflow-crd-maintenance \
     --force-conflicts --dry-run=server -f target-crds.yaml
   kubectl apply --server-side --field-manager=kubeflow-crd-maintenance \
     --force-conflicts -f target-crds.yaml
   ```

   `--force-conflicts` here belongs to `kubectl apply` on the definitions-only
   file. It is not a flag for `helm upgrade` of the release.
4. Check that every definition is established, then upgrade the release:

   ```bash
   kubectl wait --for=condition=Established \
     crd/experiments.kubeflow.org crd/suggestions.kubeflow.org crd/trials.kubeflow.org
   helm upgrade katib applications/katib/helm --namespace kubeflow \
     --values applications/katib/helm/ci/values-kubeflow.yaml
   ```

   Keep the same field manager for later updates. One forced handover does not
   rule out later conflicts on fields that are still shared.
5. When the definitions are administrator-managed, reinstall with
   `--skip-crds`, and have compatible definitions present first:

   ```bash
   helm install katib applications/katib/helm --namespace kubeflow \
     --values applications/katib/helm/ci/values-kubeflow.yaml \
     --skip-crds --wait --timeout 5m
   ```

   The same flag applies to the install side of `helm upgrade --install`.
   Without it, `helm install` applies the bundled definitions again as the field
   manager `helm`.

   Observed on the Spark Operator chart of this repository, which keeps its
   definitions in a `crds/` directory as well (2026-09-21, Helm 4.2.2, field
   manager `kubeflow-crd-maintenance`). This chart has not run the same test:

   - When the bundled definitions differed from the administrator-managed ones,
     a plain `helm install` failed in under one second and left no release:
     `conflict with "kubeflow-crd-maintenance": .spec.versions`.
   - When the bundled definitions were equal, a plain `helm install` succeeded
     silently, and `helm` owned `.spec.versions` again, shared with the
     administrator field manager. The next unforced change then conflicted with
     `helm` again.
   - `helm install --skip-crds` succeeded and left the definitions, their field
     managers and the existing custom resource objects unchanged.

Never delete and recreate the definitions to settle ownership. That deletes
every Experiment, Suggestion and Trial, and the Katib finalizers
(`update-prometheus-metrics`, `clean-metrics-in-db`) block the deletion while no
controller runs (observed 2026-09-21).

## Database credentials

| Consumer | Key it reads | Governed by |
| --- | --- | --- |
| MySQL Deployment, its probes, and the DB manager (`DB_PASSWORD`) | `MYSQL_ROOT_PASSWORD` | `database.mysql.auth.rootPassword`, or `database.mysql.auth.existingSecret` holding that key. An empty value renders the fixed default `test`. |
| No workload in this chart | `MYSQL_PASSWORD` (random when unset) | `database.mysql.auth.password`. It is not the credential the workloads use. |
| PostgreSQL database Deployment | `POSTGRES_PASSWORD` and the other variables from the Secret | `database.postgres.auth.*`, or `database.postgres.auth.existingSecret`. The MySQL advice does not apply. |
| PostgreSQL DB manager | None. `DB_PASSWORD` is hardcoded to `katib` in `templates/_helpers.tpl`. | Nothing. It reads neither the Secret nor the password values. |
| External database | `DB_PASSWORD` and the connection keys | `database.external.existingSecret` |

- The fixed default root password `test` matches the Kustomize baseline. It is
  not suitable for production. Set `database.mysql.auth.rootPassword` or supply
  an existing Secret at the first installation.
- Existing limitation: a PostgreSQL password other than `katib` does not work
  with this chart, because the DB manager does not read it.
- A render without `database.mysql.auth.password` generates a new random
  `MYSQL_PASSWORD` on every installation and upgrade, and a render without
  `database.postgres.auth.password` does the same for `POSTGRES_PASSWORD`. The
  chart defaults also generate a new webhook `tls.crt` and `tls.key` on every
  render. The seven scenario values files render none of these fields randomly.
- For an existing installation, **preserve the credential that works today**.
  Pass the same values or the same existing Secret as at installation. A new
  password value changes the Secret, but it does not rotate the account that
  the database stored on the PersistentVolumeClaim, so the DB manager then
  fails to connect. This chart provides no rotation procedure.

## Storage

`helm uninstall` deletes the PersistentVolumeClaim that the chart owns
(`katib-mysql` or `katib-postgres`). Whether the backing data is deleted depends
on the reclaim policy of the PersistentVolume and its StorageClass. The chart
gives no data retention guarantee, and a keep annotation alone would not
preserve credentials or data correctness.

## Maintenance

`scripts/synchronize-katib-manifests.sh` maintains this chart only partially.
It updates `appVersion` in `Chart.yaml` and `global.imageTag` in `values.yaml`
and in the `ci/values-*.yaml` files that pin it, and it runs `helm lint`. It
does not update the collector and suggestion image pins in
`config.katibConfig`, the definitions in `crds/` or the templates. Update those
by hand when the upstream version changes. `tests/katib_helm_chart_test.py`
fails when `appVersion` or `global.imageTag` differs from `COMMIT` in the
script, or when a definition differs from `applications/katib/upstream`.

## Comparison

```bash
python3 tests/run_helm_kustomize_comparison.py katib --all-scenarios
```

How this chart is compared, including every declared allowance, is in
[`ci/comparison.yaml`](ci/comparison.yaml); the descriptor format is documented in
[`tests/README.md`](../../../tests/README.md).
