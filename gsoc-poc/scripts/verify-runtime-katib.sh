#!/usr/bin/env bash
set -euo pipefail

# Runtime verification helper for Project 5 Katib Helm PoC.
# Usage:
#   ./gsoc-poc/scripts/verify-runtime-katib.sh standalone
#   ./gsoc-poc/scripts/verify-runtime-katib.sh with-kubeflow
#   ./gsoc-poc/scripts/verify-runtime-katib.sh both

SCENARIO="${1:-both}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_DIR="$ROOT_DIR/experimental/helm/charts/katib"
NAMESPACE="${NAMESPACE:-kubeflow}"
RELEASE="${RELEASE:-katib}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"

VALUES_STANDALONE="$CHART_DIR/ci/values-standalone.yaml"
VALUES_KUBEFLOW="$CHART_DIR/ci/values-kubeflow.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_namespace() {
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
  kubectl label ns "$NAMESPACE" katib.kubeflow.org/metrics-collector-injection=enabled --overwrite >/dev/null
}

cleanup_release() {
  kubectl delete experiment -n "$NAMESPACE" -l gsoc.katib/smoke=true --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete trial -n "$NAMESPACE" -l gsoc.katib/smoke=true --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete jobs.batch -n "$NAMESPACE" -l gsoc.katib/smoke=true --ignore-not-found >/dev/null 2>&1 || true

  if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    helm uninstall "$RELEASE" -n "$NAMESPACE"
  fi

  # Remove potentially stale webhook configs from previous failed/terminated runs.
  kubectl delete mutatingwebhookconfiguration katib.kubeflow.org --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete validatingwebhookconfiguration katib.kubeflow.org --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete certificate katib-webhook-cert -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete issuer katib-selfsigned-issuer -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret katib-webhook-cert -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

  for _ in $(seq 1 180); do
    local release_objects=0
    local mysql_pvc=0
    local postgres_pvc=0
    local webhook_cert_secret=0
    local webhook_cert_resource=0
    local webhook_issuer=0

    if [[ -n "$(kubectl get all -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" --ignore-not-found -o name 2>/dev/null)" ]]; then
      release_objects=1
    fi
    kubectl get pvc "${RELEASE}-mysql" -n "$NAMESPACE" >/dev/null 2>&1 && mysql_pvc=1
    kubectl get pvc "${RELEASE}-postgres" -n "$NAMESPACE" >/dev/null 2>&1 && postgres_pvc=1
    kubectl get secret katib-webhook-cert -n "$NAMESPACE" >/dev/null 2>&1 && webhook_cert_secret=1
    kubectl get certificate katib-webhook-cert -n "$NAMESPACE" >/dev/null 2>&1 && webhook_cert_resource=1
    kubectl get issuer katib-selfsigned-issuer -n "$NAMESPACE" >/dev/null 2>&1 && webhook_issuer=1

    if [[ "$release_objects" -eq 0 && "$mysql_pvc" -eq 0 && "$postgres_pvc" -eq 0 && "$webhook_cert_secret" -eq 0 && "$webhook_cert_resource" -eq 0 && "$webhook_issuer" -eq 0 ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Katib cleanup timeout for release: $RELEASE" >&2
  kubectl get all -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" || true
  kubectl get pvc -n "$NAMESPACE" || true
  exit 1
}

install_standalone() {
  helm install "$RELEASE" "$CHART_DIR" \
    -n "$NAMESPACE" \
    -f "$VALUES_STANDALONE" \
    --set namespaceCreate.enabled=false \
    --set webhook.mutating.podMutator.enabled=false \
    --wait \
    --timeout "$HELM_TIMEOUT"
}

install_with_kubeflow() {
  helm install "$RELEASE" "$CHART_DIR" \
    -n "$NAMESPACE" \
    -f "$VALUES_KUBEFLOW" \
    --set namespaceCreate.enabled=false \
    --set webhook.mutating.podMutator.enabled=false \
    --wait \
    --timeout "$HELM_TIMEOUT"
}

wait_for_deployments() {
  kubectl rollout status deployment/"${RELEASE}-controller" -n "$NAMESPACE" --timeout=300s
  kubectl rollout status deployment/"${RELEASE}-db-manager" -n "$NAMESPACE" --timeout=300s
  kubectl rollout status deployment/"${RELEASE}-ui" -n "$NAMESPACE" --timeout=300s

  if kubectl get deployment "${RELEASE}-mysql" -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl rollout status deployment/"${RELEASE}-mysql" -n "$NAMESPACE" --timeout=300s
  fi

  if kubectl get deployment "${RELEASE}-postgres" -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl rollout status deployment/"${RELEASE}-postgres" -n "$NAMESPACE" --timeout=300s
  fi
}

webhook_smoke_check() {
  kubectl get validatingwebhookconfiguration katib.kubeflow.org >/dev/null
  kubectl get mutatingwebhookconfiguration katib.kubeflow.org >/dev/null
}

controller_health_check() {
  kubectl port-forward -n "$NAMESPACE" svc/"${RELEASE}-controller" 18081:18080 >/tmp/pf-katib-controller.log 2>&1 &
  local pf_pid=$!
  sleep 3
  curl -sSf http://127.0.0.1:18081/healthz >/dev/null
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
}

ui_smoke_check() {
  kubectl port-forward -n "$NAMESPACE" svc/"${RELEASE}-ui" 18082:80 >/tmp/pf-katib-ui.log 2>&1 &
  local pf_pid=$!
  sleep 3

  local status_root
  status_root="$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18082/ || true)"
  local status_katib
  status_katib="$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18082/katib/ || true)"

  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true

  case "$status_root:$status_katib" in
    200:*|302:*|401:*|403:*|*:200|*:302|*:401|*:403)
      return 0
      ;;
    *)
      echo "Unexpected Katib UI status codes: /=$status_root /katib/=$status_katib" >&2
      exit 1
      ;;
  esac
}

experiment_smoke_check() {
  local scenario="$1"
  local experiment_name="gsoc-smoke-${scenario}-$(date +%s)"
  local experiment_file
  experiment_file="$(mktemp)"

  cat >"$experiment_file" <<EOF
apiVersion: kubeflow.org/v1beta1
kind: Experiment
metadata:
  name: ${experiment_name}
  namespace: ${NAMESPACE}
  labels:
    gsoc.katib/smoke: "true"
spec:
  objective:
    type: maximize
    objectiveMetricName: accuracy
    goal: 0.99
  algorithm:
    algorithmName: random
  parallelTrialCount: 1
  maxTrialCount: 1
  maxFailedTrialCount: 1
  parameters:
  - name: lr
    parameterType: double
    feasibleSpace:
      min: "0.001"
      max: "0.01"
  trialTemplate:
    primaryContainerName: training-container
    trialParameters:
    - name: lr
      reference: lr
    trialSpec:
      apiVersion: batch/v1
      kind: Job
      spec:
        template:
          metadata:
            labels:
              gsoc.katib/smoke: "true"
          spec:
            containers:
            - name: training-container
              image: alpine:3.20
              command:
              - sh
              - -c
              - |
                echo "lr=\${trialParameters.lr}"
                echo "accuracy=0.90"
                sleep 5
            restartPolicy: Never
EOF

  kubectl apply -f "$experiment_file"

  local trial_count=0
  for _ in $(seq 1 120); do
    trial_count="$(kubectl get trials -n "$NAMESPACE" -l katib.kubeflow.org/experiment="$experiment_name" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$trial_count" -ge 1 ]]; then
      break
    fi
    sleep 2
  done

  if [[ "$trial_count" -lt 1 ]]; then
    echo "No Trial object created for smoke experiment: $experiment_name" >&2
    kubectl get experiment "$experiment_name" -n "$NAMESPACE" -o yaml || true
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide || true
    rm -f "$experiment_file"
    exit 1
  fi

  kubectl delete experiment "$experiment_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$experiment_file"
}

verify_runtime() {
  local scenario="$1"
  wait_for_deployments
  webhook_smoke_check
  controller_health_check
  ui_smoke_check
  experiment_smoke_check "$scenario"
  kubectl get deploy -n "$NAMESPACE"
  kubectl get pods -n "$NAMESPACE"
  kubectl get pvc -n "$NAMESPACE"
}

verify_with_kubeflow_extras() {
  kubectl get virtualservice -n "$NAMESPACE" "${RELEASE}-ui" >/dev/null
  kubectl get authorizationpolicy -n "$NAMESPACE" "${RELEASE}-ui" >/dev/null
}

run_scenario() {
  local target="$1"
  echo "[verify-runtime-katib] Running scenario: $target"
  cleanup_release

  case "$target" in
    standalone)
      install_standalone
      ;;
    with-kubeflow)
      install_with_kubeflow
      ;;
    *)
      echo "Unsupported scenario: $target (use standalone, with-kubeflow, or both)" >&2
      exit 1
      ;;
  esac

  verify_runtime "$target"
  if [[ "$target" == "with-kubeflow" ]]; then
    verify_with_kubeflow_extras
  fi

  echo "[verify-runtime-katib] Scenario passed: $target"
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
      run_scenario "standalone"
      run_scenario "with-kubeflow"
      ;;
    standalone|with-kubeflow)
      run_scenario "$SCENARIO"
      ;;
    *)
      echo "Unsupported scenario: $SCENARIO (use standalone, with-kubeflow, or both)" >&2
      exit 1
      ;;
  esac

  echo "[verify-runtime-katib] All requested runtime checks passed."
}

main "$@"
