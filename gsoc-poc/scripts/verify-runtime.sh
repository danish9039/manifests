#!/usr/bin/env bash
set -euo pipefail

# Runtime verification helper for Project 5 KFP Helm PoC.
# Usage:
#   ./gsoc-poc/scripts/verify-runtime.sh multi-user
#   ./gsoc-poc/scripts/verify-runtime.sh k8s-native
#   ./gsoc-poc/scripts/verify-runtime.sh both

SCENARIO="${1:-both}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_DIR="$ROOT_DIR/experimental/helm/charts/pipelines"
NAMESPACE="${NAMESPACE:-kubeflow}"
RELEASE="${RELEASE:-pipelines}"
HELM_TIMEOUT="${HELM_TIMEOUT:-25m}"

VALUES_MULTI="$CHART_DIR/ci/values-platform-agnostic-multi-user.yaml"
VALUES_K8S_NATIVE="$CHART_DIR/ci/values-platform-agnostic-multi-user-k8s-native.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_namespace() {
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
}

cleanup_release() {
  if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    helm uninstall "$RELEASE" -n "$NAMESPACE"
  fi

  for _ in $(seq 1 180); do
    local mysql_exists=0
    local seaweed_exists=0
    kubectl get pvc mysql-pv-claim -n "$NAMESPACE" >/dev/null 2>&1 && mysql_exists=1
    kubectl get pvc seaweedfs-pvc -n "$NAMESPACE" >/dev/null 2>&1 && seaweed_exists=1
    if [[ "$mysql_exists" -eq 0 && "$seaweed_exists" -eq 0 ]]; then
      return 0
    fi
    sleep 2
  done

  echo "PVC cleanup timeout for mysql-pv-claim/seaweedfs-pvc" >&2
  exit 1
}

prepare_metacontroller_crds() {
  helm template "$RELEASE" "$CHART_DIR" \
    -n "$NAMESPACE" \
    -f "$VALUES_K8S_NATIVE" \
    --show-only templates/crds/metacontroller-crds.yaml | kubectl apply -f -

  for crd in \
    compositecontrollers.metacontroller.k8s.io \
    controllerrevisions.metacontroller.k8s.io \
    decoratorcontrollers.metacontroller.k8s.io; do
    kubectl annotate crd "$crd" \
      meta.helm.sh/release-name="$RELEASE" \
      meta.helm.sh/release-namespace="$NAMESPACE" \
      --overwrite
    kubectl label crd "$crd" app.kubernetes.io/managed-by=Helm --overwrite
  done
}

install_multi_user() {
  prepare_metacontroller_crds

  helm install "$RELEASE" "$CHART_DIR" \
    -n "$NAMESPACE" \
    -f "$VALUES_MULTI" \
    --set thirdParty.metacontroller.enabled=false \
    --wait \
    --timeout "$HELM_TIMEOUT"
}

install_k8s_native() {
  prepare_metacontroller_crds

  helm install "$RELEASE" "$CHART_DIR" \
    -n "$NAMESPACE" \
    -f "$VALUES_K8S_NATIVE" \
    --set apiServer.image.repository=ghcr.io/kubeflow/kfp-api-server \
    --set apiServer.image.tag=2.16.0 \
    --wait \
    --timeout "$HELM_TIMEOUT"
}

api_smoke_check() {
  kubectl port-forward -n "$NAMESPACE" svc/ml-pipeline 18888:8888 >/tmp/pf-kfp-api.log 2>&1 &
  local pf_pid=$!
  sleep 3
  curl -sSf http://127.0.0.1:18888/apis/v1beta1/healthz >/dev/null
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
}

ui_smoke_check() {
  kubectl port-forward -n "$NAMESPACE" svc/ml-pipeline-ui 18080:80 >/tmp/pf-kfp-ui.log 2>&1 &
  local pf_pid=$!
  sleep 3
  curl -sSfI http://127.0.0.1:18080/ | head -n 1 >/dev/null
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
}

verify_runtime() {
  kubectl get deploy -n "$NAMESPACE"
  kubectl get pods -n "$NAMESPACE"
  kubectl get pvc -n "$NAMESPACE"
  api_smoke_check
  ui_smoke_check
}

run_scenario() {
  local target="$1"
  echo "[verify-runtime] Running scenario: $target"
  cleanup_release

  case "$target" in
    multi-user)
      install_multi_user
      ;;
    k8s-native)
      install_k8s_native
      ;;
    *)
      echo "Unsupported scenario: $target (use multi-user, k8s-native, or both)" >&2
      exit 1
      ;;
  esac

  verify_runtime
  echo "[verify-runtime] Scenario passed: $target"
}

main() {
  require_cmd helm
  require_cmd kubectl
  require_cmd curl

  if [[ ! -d "$CHART_DIR" ]]; then
    echo "Chart directory not found: $CHART_DIR" >&2
    exit 1
  fi

  ensure_namespace

  case "$SCENARIO" in
    both)
      run_scenario "multi-user"
      run_scenario "k8s-native"
      ;;
    multi-user|k8s-native)
      run_scenario "$SCENARIO"
      ;;
    *)
      echo "Unsupported scenario: $SCENARIO (use multi-user, k8s-native, or both)" >&2
      exit 1
      ;;
  esac

  echo "[verify-runtime] All requested runtime checks passed."
}

main "$@"
