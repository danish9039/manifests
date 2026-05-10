#!/bin/bash
set -euo pipefail

kustomize build common/knative/knative-eventing/overlays/security | kubectl apply -f -

kubectl rollout status deployment/eventing-controller -n knative-eventing --timeout=120s
kubectl rollout status deployment/eventing-webhook -n knative-eventing --timeout=120s
kubectl rollout status statefulset/request-reply -n knative-eventing --timeout=120s
kubectl get namespace knative-eventing -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' | grep -x restricted
kubectl get networkpolicy default-allow-same-namespace-knative-eventing -n knative-eventing
kubectl get networkpolicy webhook-apiserver -n knative-eventing
