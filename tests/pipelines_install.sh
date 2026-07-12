#!/bin/bash
set -euo pipefail

dump_pipeline_install_debug() {
  echo "=== Pipeline install debug: non-completed pods ==="
  kubectl get pods --all-namespaces --field-selector=status.phase!=Succeeded -o wide || true

  echo "=== Pipeline install debug: kubeflow deployments ==="
  kubectl get deployments -n kubeflow -o wide || true
  kubectl describe deployments -n kubeflow || true

  echo "=== Pipeline install debug: kubeflow pods ==="
  kubectl describe pods -n kubeflow || true

  echo "=== Pipeline install debug: supporting namespaces ==="
  for namespace in oauth2-proxy kube-system istio-system cert-manager kubeflow-system auth; do
    echo "--- Namespace: ${namespace} ---"
    kubectl get pods -n "${namespace}" -o wide || true
    kubectl describe pods -n "${namespace}" || true
  done

  echo "=== Pipeline install debug: persistent volume claims ==="
  kubectl get pvc --all-namespaces -o wide || true

  echo "=== Pipeline install debug: recent events ==="
  kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp || true

  echo "=== Pipeline install debug: recent pod logs ==="
  for namespace in kubeflow oauth2-proxy kube-system istio-system cert-manager kubeflow-system auth; do
    for pod in $(kubectl get pods -n "${namespace}" --field-selector=status.phase!=Succeeded -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
      echo "--- Logs: ${namespace}/${pod} ---"
      kubectl logs -n "${namespace}" "${pod}" --all-containers=true --tail=100 || true
    done
  done
}

echo "Installing Pipelines ..."
cd applications/pipeline
kubectl apply -f upstream/third-party/metacontroller/base/crd.yaml
echo "Waiting for crd/compositecontrollers.metacontroller.k8s.io to be available ..."
kubectl wait --for condition=established --timeout=30s crd/compositecontrollers.metacontroller.k8s.io
kubectl apply -f upstream/third-party/application/cluster-scoped/application-crd.yaml
echo "Waiting for crd/applications.app.k8s.io to be available ..."
kubectl wait --for condition=established --timeout=30s crd/applications.app.k8s.io
kustomize build overlays | kubectl apply -f -
sleep 60
kubectl wait --for=condition=Ready pods --all --all-namespaces --timeout=600s \
  --field-selector=status.phase!=Succeeded || (
  dump_pipeline_install_debug
  exit 1
)

kubectl wait --for=condition=Available deployment/ml-pipeline -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/ml-pipeline-ui -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/ml-pipeline-persistenceagent -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/ml-pipeline-scheduledworkflow -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/ml-pipeline-viewer-crd -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/cache-server -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/metadata-writer -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/seaweedfs -n kubeflow --timeout=10s
kubectl wait --for=condition=Available deployment/mysql -n kubeflow --timeout=10s
kubectl get deployment -n kubeflow -l app=ml-pipeline
cd -
