#!/usr/bin/env bash
# Install the API, control-plane and default-catalog releases in that order.
set -euxo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPOSITORY_ROOT"
source scripts/library.sh
require_helm_major_version 4

# The foundation release owns this shared namespace; Trainer never creates it.
kubectl get namespace kubeflow-system
helm install trainer-apis applications/trainer/helm-crds \
  --namespace kubeflow-system --wait --timeout 5m
for definition in \
  clustertrainingruntimes.trainer.kubeflow.org \
  trainingruntimes.trainer.kubeflow.org \
  trainjobs.trainer.kubeflow.org \
  jobsets.jobset.x-k8s.io; do
  kubectl wait --for=condition=Established "crd/${definition}" --timeout=120s
done

helm install trainer applications/trainer/helm \
  --namespace kubeflow-system --wait --timeout 10m
for deployment in kubeflow-trainer-controller-manager jobset-controller-manager; do
  kubectl rollout status "deployment/${deployment}" \
    --namespace kubeflow-system --timeout=300s
done

# Preserve the established installer workaround until live testing establishes
# that the JobSet controller no longer needs to reload its serving certificate.
kubectl rollout restart deployment/jobset-controller-manager --namespace kubeflow-system
kubectl rollout status deployment/jobset-controller-manager \
  --namespace kubeflow-system --timeout=300s

for webhook in \
  mutatingwebhookconfiguration/defaulter.trainer.kubeflow.org \
  mutatingwebhookconfiguration/jobset-mutating-webhook-configuration \
  validatingwebhookconfiguration/validator.trainer.kubeflow.org \
  validatingwebhookconfiguration/jobset-validating-webhook-configuration; do
  kubectl wait "$webhook" --timeout=120s \
    --for='jsonpath={.webhooks[0].clientConfig.caBundle}'
done
for service in kubeflow-trainer-controller-manager jobset-webhook-service; do
  kubectl wait "endpoints/${service}" --namespace kubeflow-system \
    --for='jsonpath={.subsets[0].addresses[0].ip}' --timeout=120s
done

helm install trainer-runtimes applications/trainer/helm-runtimes \
  --namespace kubeflow-system --wait --timeout 5m
kubectl get clustertrainingruntimes
