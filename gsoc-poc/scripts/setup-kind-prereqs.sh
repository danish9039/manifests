#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-kubeflow-gsoc-p5}"
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-true}"
INSTALL_ISTIO_CNI="${INSTALL_ISTIO_CNI:-true}"
PRELOAD_RUNTIME_IMAGES="${PRELOAD_RUNTIME_IMAGES:-false}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

install_cert_manager() {
  echo "[setup-kind-prereqs] Installing cert-manager."
  (cd "$ROOT_DIR/common/cert-manager" && kustomize build base | kubectl apply -f -)

  kubectl rollout status -n cert-manager deployment/cert-manager --timeout=300s
  kubectl rollout status -n cert-manager deployment/cert-manager-cainjector --timeout=300s
  kubectl rollout status -n cert-manager deployment/cert-manager-webhook --timeout=300s

  # Overlay resources can fail briefly while webhook endpoint is still warming up.
  local applied="false"
  for _ in $(seq 1 20); do
    if (cd "$ROOT_DIR/common/cert-manager" && kustomize build overlays/kubeflow | kubectl apply -f -); then
      applied="true"
      break
    fi
    sleep 5
  done

  if [[ "$applied" != "true" ]]; then
    echo "Failed to apply cert-manager kubeflow overlay after retries." >&2
    exit 1
  fi

  kubectl rollout status -n cert-manager deployment/cert-manager --timeout=300s
  kubectl rollout status -n cert-manager deployment/cert-manager-cainjector --timeout=300s
  kubectl rollout status -n cert-manager deployment/cert-manager-webhook --timeout=300s
}

install_istio_cni() {
  echo "[setup-kind-prereqs] Installing Istio CNI."
  (cd "$ROOT_DIR/common/istio" && kustomize build istio-crds/base | kubectl apply -f -)
  (cd "$ROOT_DIR/common/istio" && kustomize build istio-namespace/base | kubectl apply -f -)
  (cd "$ROOT_DIR/common/istio" && kustomize build istio-install/overlays/oauth2-proxy | kubectl apply -f -)
  kubectl wait --for=condition=Ready pod --all -n istio-system --timeout=300s
}

main() {
  require_cmd kind
  require_cmd kubectl
  require_cmd kustomize
  require_cmd helm

  if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
    echo "[setup-kind-prereqs] Creating Kind cluster: $CLUSTER_NAME"
    kind create cluster --name "$CLUSTER_NAME"
  else
    echo "[setup-kind-prereqs] Reusing existing Kind cluster: $CLUSTER_NAME"
  fi

  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

  cd "$ROOT_DIR"
  kubectl get ns kubeflow >/dev/null 2>&1 || kubectl create namespace kubeflow

  if [[ "$PRELOAD_RUNTIME_IMAGES" == "true" ]]; then
    echo "[setup-kind-prereqs] Preloading runtime images into kind cluster."
    "$ROOT_DIR/gsoc-poc/scripts/preload-kind-images.sh"
  fi

  if [[ "$INSTALL_CERT_MANAGER" == "true" ]]; then
    install_cert_manager
  else
    echo "[setup-kind-prereqs] Skipping cert-manager install."
  fi

  if [[ "$INSTALL_ISTIO_CNI" == "true" ]]; then
    install_istio_cni
  else
    echo "[setup-kind-prereqs] Skipping Istio CNI install."
  fi

  echo "[setup-kind-prereqs] Prerequisite setup completed."
}

main "$@"
