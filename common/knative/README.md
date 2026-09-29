# Knative

## Knative-Serving

Please check the synchronization script under /scripts.

### Changes from upstream

- The `knative-ingress-gateway` Gateway is removed since we use the Kubeflow gateway.
- In `config-istio`, the Knative gateway is set to use `gateway.kubeflow.kubeflow-gateway`.
- In `config-deployment`, `progressDeadline` is set to `600s` as sometimes large models need longer than
  the default of `120s` to start the containers.

## Knative-Eventing

Please check the synchronization script under /scripts.

### PingSource adapter ownership

The Eventing security overlay omits the PingSource adapter's bootstrap replica
count and controller-managed environment entries. Both Kustomize and generated
Helm installations leave these fields to the PingSource controller, rather than
resetting its runtime configuration during updates. The imported upstream bundle
is unchanged.

Kubernetes defaults the adapter to one idle Pod, requesting 125m CPU and 64Mi
memory, before the first PingSource is created. Previously the Kustomize
installation started at zero. The controller scales zero to one for a source but
does not scale back to zero when the last source is deleted.

For an existing client-side-applied Kustomize installation, the first application
of the corrected overlay can clear fields recorded in the old
`kubectl.kubernetes.io/last-applied-configuration` annotation and trigger an adapter
rollout. A manually increased replica count can reset to the Kubernetes default
of one. Verify fresh event delivery and restore any administrator-selected replica
count after this first update. Subsequent applies leave the omitted fields to the
controller. Do not assume a disruption-free migration from the previous overlay.
