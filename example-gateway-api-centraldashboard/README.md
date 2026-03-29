# example-gateway-api-centraldashboard

This wrapper keeps the normal `example/` installation content and layers a bounded Gateway API route for `centraldashboard` on top.

Use it when you want to inspect the smallest example-shaped Track C composition in one place.

## Render

```bash
kubectl kustomize example-gateway-api-centraldashboard
```

## Intent

This is not a new full example tree. It is a thin composition that helps review the route addition in isolation.
