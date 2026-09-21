#!/usr/bin/env bash
# Install Models UI after the foundation, authentication edge, Istio and KServe.
set -euo pipefail
SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPOSITORY_ROOT=$(dirname "$SCRIPT_DIRECTORY")
helm upgrade --install kserve-models-web-application \
  "${REPOSITORY_ROOT}/applications/kserve/kserve-ui/helm" \
  --namespace kserve --reset-values --wait --timeout 5m
kubectl rollout status deployment/kserve-models-web-application \
  --namespace kserve --timeout=300s
