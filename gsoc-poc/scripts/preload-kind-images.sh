#!/usr/bin/env bash
set -euo pipefail

# Pre-pull and load runtime images into the Kind cluster so repeated PoC runs
# don't spend time re-pulling the same images from remote registries.

CLUSTER_NAME="${CLUSTER_NAME:-kubeflow-gsoc-p5}"
PULL_TIMEOUT_SECONDS="${PULL_TIMEOUT_SECONDS:-600}"
PULL_RETRIES="${PULL_RETRIES:-3}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

preload_image() {
  local image="$1"

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    local pulled=0
    local attempt
    for attempt in $(seq 1 "$PULL_RETRIES"); do
      echo "[preload-kind-images] pulling ($attempt/$PULL_RETRIES): $image"
      if timeout "$PULL_TIMEOUT_SECONDS" docker pull "$image" >/dev/null; then
        pulled=1
        break
      fi
      echo "[preload-kind-images] pull attempt failed for $image"
      sleep 2
    done

    if [[ "$pulled" -ne 1 ]]; then
      echo "[preload-kind-images] failed to pull after retries: $image" >&2
      return 1
    fi
  else
    echo "[preload-kind-images] cached: $image"
  fi

  echo "[preload-kind-images] loading into kind-$CLUSTER_NAME: $image"
  if ! kind load docker-image --name "$CLUSTER_NAME" "$image" >/dev/null; then
    echo "[preload-kind-images] failed to load into kind cluster: $image" >&2
    return 1
  fi
}

print_failures() {
  local -a failed=("$@")
  echo "[preload-kind-images] failed images (${#failed[@]}):" >&2
  local image
  for image in "${failed[@]}"; do
    echo "  - $image" >&2
  done
}

main() {
  require_cmd docker
  require_cmd kind

  if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
    echo "Kind cluster not found: $CLUSTER_NAME" >&2
    echo "Run setup-kind-prereqs first, or set CLUSTER_NAME to an existing cluster." >&2
    exit 1
  fi

  local -a images=(
    # KFP runtime
    "ghcr.io/kubeflow/kfp-api-server:2.16.0"
    "ghcr.io/kubeflow/kfp-cache-server:2.16.0"
    "ghcr.io/kubeflow/kfp-frontend:2.16.0"
    "ghcr.io/kubeflow/kfp-metadata-envoy:2.16.0"
    "ghcr.io/kubeflow/kfp-metadata-writer:2.16.0"
    "ghcr.io/kubeflow/kfp-persistence-agent:2.16.0"
    "ghcr.io/kubeflow/kfp-scheduled-workflow-controller:2.16.0"
    "ghcr.io/kubeflow/kfp-viewer-crd-controller:2.16.0"
    "ghcr.io/kubeflow/kfp-visualization-server:2.16.0"
    "quay.io/argoproj/argocli:v3.5.5"
    "quay.io/argoproj/workflow-controller:v3.5.5"
    "quay.io/argoproj/workflow-controller:v3.7.3"
    "docker.io/alpine/k8s:1.32.3"
    "gcr.io/tfx-oss-public/ml_metadata_store_server:1.14.0"
    "mysql:8.4"
    "chrislusf/seaweedfs:4.00"

    # Katib runtime
    "ghcr.io/kubeflow/katib/katib-controller:v0.19.0"
    "ghcr.io/kubeflow/katib/katib-db-manager:v0.19.0"
    "ghcr.io/kubeflow/katib/katib-ui:v0.19.0"
    "ghcr.io/kubeflow/katib/suggestion-hyperopt:v0.19.0"
    "ghcr.io/kubeflow/katib/file-metrics-collector:v0.19.0"
    "mysql:8.0"
  )

  local -a failed_images=()
  local image
  for image in "${images[@]}"; do
    if ! preload_image "$image"; then
      failed_images+=("$image")
    fi
  done

  if [[ "${#failed_images[@]}" -gt 0 ]]; then
    print_failures "${failed_images[@]}"
    exit 1
  fi

  echo "[preload-kind-images] completed for cluster: $CLUSTER_NAME"
}

main "$@"
