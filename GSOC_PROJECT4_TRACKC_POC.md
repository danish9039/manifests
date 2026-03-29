# GSoC 2026 Project 4 Track C PoC

This branch contains a bounded Gateway API coexistence proof of concept for Project 4.

## What this track demonstrates

Track C is about migrating selected Kubeflow application routes toward Gateway API without forcing a full cutover in one step.

This branch shows that approach on two application routes:

- `centraldashboard`
- `volumes-web-app`

The branch keeps the existing Istio `VirtualService` route path in place and adds Gateway API resources beside it. The goal is coexistence first, then gradual migration.

## What changed

- Added a `gateway-api-route` component for `centraldashboard`
- Added a `gateway-api-route` component for `volumes-web-app`
- Added Gateway API overlays that layer on top of the existing Istio overlays
- Added a focused example wrapper for `centraldashboard`
- Patched authorization-policy selection so the Gateway API service account can reach the app workload without widening the policy unnecessarily

## Where to look

- `applications/centraldashboard/upstream/components/gateway-api-route/`
- `applications/centraldashboard/upstream/overlays/istio-gateway-api/`
- `applications/centraldashboard/upstream/overlays/kserve-gateway-api/`
- `applications/centraldashboard/overlays/oauth2-proxy-gateway-api/`
- `applications/volumes-web-app/upstream/components/gateway-api-route/`
- `applications/volumes-web-app/upstream/overlays/istio-gateway-api/`
- `example-gateway-api-centraldashboard/`

## Quick local checks

Render the main overlays:

```bash
kubectl kustomize applications/centraldashboard/overlays/oauth2-proxy-gateway-api
kubectl kustomize applications/volumes-web-app/upstream/overlays/istio-gateway-api
kubectl kustomize example-gateway-api-centraldashboard
```

If you have Gateway API CRDs installed in a local cluster, you can also server-side dry-run the manifests:

```bash
kubectl apply --dry-run=server -k applications/centraldashboard/overlays/oauth2-proxy-gateway-api
kubectl apply --dry-run=server -k applications/volumes-web-app/upstream/overlays/istio-gateway-api
```

## What is intentionally not included

- a repo-wide Gateway API migration
- a full replacement of existing Istio routing
- Track A scalability code
- Track B Pipelines security changes
- Track D Trainer zero-trust validation helpers

This branch is intentionally small. It is meant to show a safe migration pattern, not a full platform rewrite.
