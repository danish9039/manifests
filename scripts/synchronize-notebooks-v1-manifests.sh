#!/usr/bin/env bash
# This script helps to create a PR to update the Notebooks v1 manifests
SCRIPT_DIRECTORY=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIRECTORY}/library.sh"
setup_error_handling
COMPONENT_NAME="notebooks-v1"
REPOSITORY_NAME="kubeflow/notebooks"
REPOSITORY_URL="https://github.com/kubeflow/notebooks.git"
COMMIT="v1.11.0"
REPOSITORY_DIRECTORY="$COMPONENT_NAME"
SOURCE_DIRECTORY=${SOURCE_DIRECTORY:=/tmp/${COMPONENT_NAME}-${COMPONENT_NAME}}
BRANCH_NAME=${BRANCH_NAME:=synchronize-${COMPONENT_NAME}-${COMPONENT_NAME}-manifests-${COMMIT?}}
MANIFESTS_DIRECTORY=$(dirname $SCRIPT_DIRECTORY)
create_branch "$BRANCH_NAME"
clone_and_checkout "$SOURCE_DIRECTORY" "$REPOSITORY_URL" "$REPOSITORY_DIRECTORY" "$COMMIT"
copy_component_manifests() {
    local source_manifests_path=$1
    local destination_manifests_path=$2
    local destination_directory="${MANIFESTS_DIRECTORY}/${destination_manifests_path}"
    if [ -d "$destination_directory" ]; then
        rm -r "$destination_directory"
    fi
    mkdir -p "$destination_directory"
    cp "${SOURCE_DIRECTORY}/${REPOSITORY_DIRECTORY}/${source_manifests_path}/"* "$destination_directory" -r
    local source_text="\[.*\](https://github.com/${REPOSITORY_NAME}/tree/.*/)"
    local destination_text="\[${COMMIT}\](https://github.com/${REPOSITORY_NAME}/tree/${COMMIT}/)"
    update_readme "$MANIFESTS_DIRECTORY" "$source_text" "$destination_text"
}
TARGET_DIRECTORY="applications/notebooks-v1/upstream"
HELM_CHART_PATH="applications/notebooks-v1/helm"
HELM_CHART_DIRECTORY="${MANIFESTS_DIRECTORY}/${HELM_CHART_PATH}"
HELM_PLATFORM_TEMPLATE="${HELM_CHART_DIRECTORY}/templates/platform.yaml"

update_notebooks_helm_chart() {
    local chart_yaml="${HELM_CHART_DIRECTORY}/Chart.yaml"

    update_helm_chart_application_version "$chart_yaml" "$COMMIT"
    render_kustomize_helm_template "$MANIFESTS_DIRECTORY" \
        "${HELM_CHART_PATH}/kustomize" \
        "platform" \
        "$HELM_PLATFORM_TEMPLATE"
}

copy_component_manifests "components/crud-web-apps/jupyter/manifests" \
    "${TARGET_DIRECTORY}/jupyter-web-app"
copy_component_manifests "components/crud-web-apps/volumes/manifests" \
    "${TARGET_DIRECTORY}/volumes-web-app"
copy_component_manifests "components/crud-web-apps/tensorboards/manifests" \
    "${TARGET_DIRECTORY}/tensorboards-web-app"
copy_component_manifests "components/notebook-controller/config" \
    "${TARGET_DIRECTORY}/notebook-controller"
copy_component_manifests "components/tensorboard-controller/config" \
    "${TARGET_DIRECTORY}/tensorboard-controller"
copy_component_manifests "components/pvcviewer-controller/config" \
    "${TARGET_DIRECTORY}/pvcviewer-controller"

update_notebooks_helm_chart

commit_changes "$MANIFESTS_DIRECTORY" "Update ${REPOSITORY_NAME} manifests to ${COMMIT}" \
  "${TARGET_DIRECTORY}" \
  "${HELM_CHART_PATH}/Chart.yaml" \
  "${HELM_CHART_PATH}/kustomize/kustomization.yaml" \
  "${HELM_CHART_PATH}/templates/platform.yaml" \
  "${SCRIPT_DIRECTORY}/synchronize-notebooks-v1-manifests.sh" \
  "README.md"
echo "Synchronization completed successfully."
