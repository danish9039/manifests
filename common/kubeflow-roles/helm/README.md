# Kubeflow Platform Helm Chart

This chart renders the Kubeflow-owned shared platform RBAC resources from `common/kubeflow-roles/base`.

It creates the aggregate `ClusterRole` resources used by Kubeflow platform components:

- `kubeflow-admin`
- `kubeflow-edit`
- `kubeflow-view`
- `kubeflow-kubernetes-admin`
- `kubeflow-kubernetes-edit`
- `kubeflow-kubernetes-view`

Install after `kubeflow-namespaces`, with release metadata stored in `kubeflow-system`:

```bash
helm install kubeflow-platform ./common/kubeflow-roles/helm --namespace kubeflow-system
```

## Upgrading

`kubeflow-admin`, `kubeflow-edit` and `kubeflow-view` carry an `aggregationRule`, so the Kubernetes RBAC aggregation controller owns their `.rules`. The templates ship no `rules` field on them. They used to ship `rules: []`, and with Helm 4 server-side apply a plain `helm upgrade` stopped with `conflict with "clusterrole-aggregation-controller": .rules` on all three. Observed on a cluster on 2026-09-21 (Helm 4.2.2, Kubernetes 1.36.1, no `--force-conflicts`): the upgrade from such a release to the corrected chart, an unchanged upgrade and a rollback between corrected revisions succeeded, and the three roles were not written at all.

A chart update does not rewrite the release records that Helm already stored. A revision stored before the correction still contains `rules: []`, so `helm rollback` to such a revision can reproduce the conflict. On the Notebooks v1 chart that rollback failed and left the release without a `deployed` revision (observed 2026-09-21). Recover with an upgrade to the corrected chart and the intended values, then check the release and the roles:

```bash
helm upgrade kubeflow-platform ./common/kubeflow-roles/helm --namespace kubeflow-system
helm status kubeflow-platform --namespace kubeflow-system
kubectl get clusterrole kubeflow-admin kubeflow-edit kubeflow-view
```

Do not delete release history to work around it.

Validate parity with:

```bash
python3 tests/run_helm_kustomize_comparison.py kubeflow-platform platform-cluster-roles
```

The parity comparison treats an empty `rules` list and an absent one as equal, so the render test guards the omitted field:

```bash
python3 tests/kubeflow_roles_helm_chart_test.py
```

How this chart is compared, including every declared allowance, is in
[`ci/comparison.yaml`](ci/comparison.yaml); the descriptor format is documented in
[`tests/README.md`](../../../tests/README.md).
