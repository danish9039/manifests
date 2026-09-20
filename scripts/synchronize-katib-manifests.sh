#!/usr/bin/env bash
# This script helps to create a PR to update the Katib manifests
SCRIPT_DIRECTORY=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIRECTORY}/library.sh"
setup_error_handling
COMPONENT_NAME="katib"
REPOSITORY_NAME="kubeflow/katib"
REPOSITORY_URL="https://github.com/kubeflow/katib.git"
COMMIT="v0.19.0"
REPOSITORY_DIRECTORY="katib"
SOURCE_DIRECTORY=${SOURCE_DIRECTORY:=/tmp/kubeflow-${COMPONENT_NAME}}
BRANCH_NAME=${BRANCH_NAME:=synchronize-${COMPONENT_NAME}-manifests-${COMMIT?}}
MANIFESTS_DIRECTORY=$(dirname $SCRIPT_DIRECTORY)
SOURCE_MANIFESTS_PATH="manifests/v1beta1"
DESTINATION_MANIFESTS_PATH="applications/${COMPONENT_NAME}/upstream"
SOURCE_TEXT="\[.*\](https://github.com/${REPOSITORY_NAME}/tree/.*/manifests/v1beta1)"
DESTINATION_TEXT="\[${COMMIT}\](https://github.com/${REPOSITORY_NAME}/tree/${COMMIT}/manifests/v1beta1)"
HELM_CHART_PATH="applications/${COMPONENT_NAME}/helm"
HELM_CHART_DIRECTORY="${MANIFESTS_DIRECTORY}/${HELM_CHART_PATH}"

# Partial maintenance: only the application version and global.imageTag follow
# COMMIT. The collector and suggestion image pins in config.katibConfig, the
# CustomResourceDefinitions in crds and the templates are maintained by hand.
update_katib_helm_chart() {
    local values_file

    update_helm_chart_application_version "${HELM_CHART_DIRECTORY}/Chart.yaml" "$COMMIT"
    for values_file in "${HELM_CHART_DIRECTORY}/values.yaml" "${HELM_CHART_DIRECTORY}"/ci/values-*.yaml; do
        # Rewrite only the imageTag key directly under the top-level global key.
        sed -i "/^global:/,/^[^[:space:]#]/ s|^  imageTag: .*|  imageTag: ${COMMIT}|" "$values_file"
    done
}

validate_katib_helm_chart() {
    helm lint "$HELM_CHART_DIRECTORY" --namespace kubeflow
    # Parity is compared in continuous integration, by the "Compare katib"
    # job, with its pinned Helm version.
}

require_helm_major_version 4
create_branch "$BRANCH_NAME"
clone_and_checkout "$SOURCE_DIRECTORY" "$REPOSITORY_URL" "$REPOSITORY_DIRECTORY" "$COMMIT"
copy_manifests "${SOURCE_DIRECTORY}/${REPOSITORY_DIRECTORY}/${SOURCE_MANIFESTS_PATH}" "${MANIFESTS_DIRECTORY}/${DESTINATION_MANIFESTS_PATH}"
update_readme "$MANIFESTS_DIRECTORY" "$SOURCE_TEXT" "$DESTINATION_TEXT"
update_katib_helm_chart
validate_katib_helm_chart
commit_changes "$MANIFESTS_DIRECTORY" "Update ${REPOSITORY_NAME} manifests from ${COMMIT}" \
  "${DESTINATION_MANIFESTS_PATH}" \
  "${HELM_CHART_PATH}/Chart.yaml" \
  "${HELM_CHART_PATH}/values.yaml" \
  "${HELM_CHART_PATH}/ci" \
  "${SCRIPT_DIRECTORY}/synchronize-katib-manifests.sh" \
  "README.md"
echo "Synchronization completed successfully."
