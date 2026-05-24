# Kubeflow Hub Helm Chart

A Helm chart for deploying the Kubeflow Hub / Model Registry.

## Description

The Kubeflow Hub provides resources for model metadata, versions, lineage, and
related registry workflows.

## Kustomize Mapping

This chart is an experimental Helm equivalent for selected resources under:

```text
applications/hub/upstream
```

The chart name remains `hub` because the synced upstream repository is
`kubeflow/hub`. Resource names still use `model-registry` where the current
Kustomize manifests do.

## Install Contract

Current comparison scenarios render into the `kubeflow` namespace:

```bash
helm install hub ./experimental/helm/charts/hub \
  --namespace kubeflow \
  --values ./experimental/helm/charts/hub/ci/values-postgres.yaml
```

For a full Kubeflow platform install, Hub / Model Registry namespace behavior is
still being refined upstream. In particular, Model Registry may need to run in a
profile namespace, while Model Catalog may remain a central read-only service in
`kubeflow`. Keep this chart aligned with the current Kustomize paths until that
platform overlay is settled.

## Current Scope

Supported Helm/Kustomize comparison scenarios include base server resources,
database overlays, controller pieces, UI overlays, Istio resources, CSI, and
monitoring-related resources.

Model Catalog manifests under `applications/hub/upstream/options/catalog` are
not templated by this chart yet. Treat Model Catalog support and any
profile-namespace platform mode as follow-up design work.
