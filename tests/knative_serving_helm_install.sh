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

if helm status "$release" --namespace "$namespace" >/dev/null 2>&1; then
    # Never move a live release back to a bootstrap phase: Helm would prune it.
    helm upgrade "$release" "$chart" --namespace "$namespace" --wait --timeout 10m
else
    helm install "$release" "$chart" --namespace "$namespace" \
        --set installation.phase=definitions --wait --timeout 5m
    kubectl wait --for=condition=Established --timeout=120s \
        -f "$chart/manifests/platform-crds.yaml"
    helm upgrade "$release" "$chart" --namespace "$namespace" \
        --set installation.phase=controllers --wait --timeout 10m
    kubectl rollout status deployment/webhook -n knative-serving --timeout=120s
    kubectl rollout status deployment/net-istio-webhook -n knative-serving --timeout=120s
    helm upgrade "$release" "$chart" --namespace "$namespace" --wait --timeout 10m
fi
for deployment in activator autoscaler controller net-istio-controller net-istio-webhook webhook; do
    kubectl rollout status "deployment/$deployment" -n knative-serving --timeout=120s
done
