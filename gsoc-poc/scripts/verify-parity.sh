#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd python3
  require_cmd helm
  require_cmd kustomize

  cd "$ROOT_DIR"

  # Build chart dependencies only if vendored artifacts are missing.
  if [[ ! -f "experimental/helm/charts/pipelines/charts/argo-workflows-0.40.14.tgz" ]] || \
     [[ ! -f "experimental/helm/charts/pipelines/charts/mysql-14.0.3.tgz" ]]; then
    echo "[verify-parity] Building pipelines chart dependencies."
    helm dependency build experimental/helm/charts/pipelines
  fi

  echo "[verify-parity] Katib: full parity matrix."
  ./tests/helm_kustomize_compare_all.sh katib

  echo "[verify-parity] KFP: platform-agnostic-multi-user."
  ./tests/helm_kustomize_compare.sh pipelines platform-agnostic-multi-user

  echo "[verify-parity] KFP: platform-agnostic-multi-user-k8s-native."
  ./tests/helm_kustomize_compare.sh pipelines platform-agnostic-multi-user-k8s-native

  echo "[verify-parity] All Project 5 parity checks passed."
}

main "$@"
