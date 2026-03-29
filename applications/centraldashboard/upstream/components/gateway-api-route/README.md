# centraldashboard Gateway API route component

This component adds a small Gateway API routing slice for `centraldashboard`.

## Files

- `gateway.yaml`: creates a dedicated `Gateway`
- `httproute.yaml`: routes HTTP traffic to the existing `centraldashboard` Service
- `kustomization.yaml`: bundles the component and patches workload labels plus the existing `AuthorizationPolicy`

## Why the patches exist

The workload label patch gives the authorization policy a precise target. The policy patch adds the Gateway API service account principal so the new route can work without opening access more broadly than needed.

This is a coexistence component. It is designed to sit beside the existing Istio route, not replace the whole path in one change.
