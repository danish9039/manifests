#!/usr/bin/env bash
# Bootstrap APIs, then admission controllers, then their custom resources.
set -euo pipefail
chart=common/knative/knative-serving/helm
release=knative-serving
namespace=kubeflow

# This installer owns only Knative. The platform Istio release must already own
# the Kubeflow and cluster-local gateways; no raw Istio apply happens here.
kubectl get namespace "$namespace" >/dev/null
kubectl get deployment istiod -n istio-system >/dev/null
kubectl get service cluster-local-gateway -n istio-system >/dev/null

phase=definitions
if helm status "$release" --namespace "$namespace" >/dev/null 2>&1; then
    phase=$(helm get values "$release" --namespace "$namespace" -o json | \
        python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("installation", {}).get("phase", "complete"))')
else
    helm install "$release" "$chart" --namespace "$namespace" \
        --set installation.phase=definitions --wait --timeout 5m
fi
case "$phase" in
    definitions)
        kubectl wait --for=condition=Established --timeout=120s \
            -f "$chart/manifests/platform-crds.yaml"
        ;;
    controllers|complete) ;;
    *) echo "Unknown saved bootstrap phase: $phase" >&2; exit 1 ;;
esac
if [[ "$phase" != complete ]]; then
    # Resume bootstrap forward; never prune a complete release back to a phase.
    helm upgrade "$release" "$chart" --namespace "$namespace" --reset-values \
        --set installation.phase=controllers --wait --timeout 10m
    kubectl rollout status deployment/webhook -n knative-serving --timeout=120s
    kubectl rollout status deployment/net-istio-webhook -n knative-serving --timeout=120s
fi
# Deployment readiness alone does not prove admission registration has finished.
./tests/knative_serving_helm_admission_test.sh
# Helm may otherwise preserve saved bootstrap values when no new values are given.
helm upgrade "$release" "$chart" --namespace "$namespace" --reset-values \
    --set installation.phase=complete --wait --timeout 10m
for deployment in activator autoscaler controller net-istio-controller net-istio-webhook webhook; do
    kubectl rollout status "deployment/$deployment" -n knative-serving --timeout=120s
done
