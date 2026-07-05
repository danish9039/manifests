#!/bin/bash
set -euxo pipefail
echo "Installing cert-manager ..."
cd common/cert-manager
kustomize build base | kubectl apply -f -
echo "Waiting for cert-manager-webhook to be ready ..."
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kustomize build overlays/kubeflow | kubectl apply -f -
echo "Waiting for all cert-manager components to be ready ..."
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kubectl wait --for=jsonpath='{.subsets[0].addresses[0].targetRef.kind}'=Pod endpoints -l 'app in (cert-manager,webhook)' --timeout=180s -n cert-manager
