# volumes-web-app Gateway API route component

This component adds the same bounded Gateway API migration pattern for `volumes-web-app`.

## Files

- `gateway.yaml`: creates a dedicated `Gateway`
- `httproute.yaml`: routes `/volumes/` traffic to the existing `volumes-web-app-service`
- `kustomization.yaml`: bundles the component and patches workload labels, sidecar injection, and the existing `AuthorizationPolicy`

## Why this route matters

`volumes-web-app` is a useful second slice because it proves the pattern is not only a `centraldashboard` special case. The goal is to show that the coexistence model can be repeated on another app route with a different path and service name.
