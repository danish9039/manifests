#!/usr/bin/env bash
# This script helps to create a PR to update the KServe manifests
SCRIPT_DIRECTORY=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIRECTORY}/library.sh"
setup_error_handling
COMPONENT_NAME="kserve"
REPOSITORY_NAME="kserve/kserve"
REPOSITORY_URL="https://github.com/kserve/kserve.git"
COMMIT="v0.20.0"
REPOSITORY_DIRECTORY="kserve"
SOURCE_DIRECTORY=${SOURCE_DIRECTORY:=/tmp/${COMPONENT_NAME}}
BRANCH_NAME=${BRANCH_NAME:=synchronize-${COMPONENT_NAME}-manifests-${COMMIT?}}
MANIFESTS_DIRECTORY=$(dirname $SCRIPT_DIRECTORY)
SOURCE_MANIFESTS_PATH="install/${COMMIT}"
DESTINATION_MANIFESTS_PATH="applications/${COMPONENT_NAME}/${COMPONENT_NAME}/upstream"
SOURCE_TEXT="\[.*\](https://github.com/${REPOSITORY_NAME}/tree/.*)"
DESTINATION_TEXT="\[${COMMIT}\](https://github.com/${REPOSITORY_NAME}/tree/${COMMIT})"
create_branch "$BRANCH_NAME"
clone_and_checkout "$SOURCE_DIRECTORY" "$REPOSITORY_URL" "$REPOSITORY_DIRECTORY" "$COMMIT"
DESTINATION_DIRECTORY=$MANIFESTS_DIRECTORY/$DESTINATION_MANIFESTS_PATH
HELM_CHART_PATH="applications/${COMPONENT_NAME}/${COMPONENT_NAME}/helm"
HELM_CHART_DIRECTORY="${MANIFESTS_DIRECTORY}/${HELM_CHART_PATH}"

# The generated payload is the unpacked kserve-payload chart, an internal
# dependency of the kserve chart. Both carry the upstream application version,
# and Helm requires the dependency version that the parent declares to match
# the version of the chart under charts/.
HELM_PAYLOAD_CHART_PATH="${HELM_CHART_PATH}/charts/kserve-payload"
HELM_PAYLOAD_CHART_DIRECTORY="${MANIFESTS_DIRECTORY}/${HELM_PAYLOAD_CHART_PATH}"

update_kserve_helm_chart() {
    local dependency_version
    local payload_version

    update_helm_chart_application_version "${HELM_CHART_DIRECTORY}/Chart.yaml" "$COMMIT"
    update_helm_chart_application_version "${HELM_PAYLOAD_CHART_DIRECTORY}/Chart.yaml" "$COMMIT"
    dependency_version=$(awk '
        $1 == "-" && $2 == "name:" { dependency = ($3 == "kserve-payload") }
        dependency && $1 == "version:" { print $2; exit }
    ' "${HELM_CHART_DIRECTORY}/Chart.yaml")
    payload_version=$(awk '$1 == "version:" { print $2; exit }' \
        "${HELM_PAYLOAD_CHART_DIRECTORY}/Chart.yaml")
    if [[ -z "$dependency_version" || "$dependency_version" != "$payload_version" ]]; then
        echo "ERROR: the kserve chart depends on kserve-payload version" \
            "'${dependency_version}', but ${HELM_PAYLOAD_CHART_PATH} declares" \
            "'${payload_version}'." >&2
        exit 1
    fi
    python3 "${SCRIPT_DIRECTORY}/generate-kserve-helm-manifests.py" \
        --repository-root "$MANIFESTS_DIRECTORY"
}

validate_kserve_helm_chart() {
    # The chart refuses any namespace but kserve, so the linter needs it too.
    # The dependency is an unpacked directory, so no dependency build runs.
    helm lint "$HELM_CHART_DIRECTORY" --namespace kserve
    # Parity is compared in continuous integration, by the
    # "Compare ${COMPONENT_NAME}" job, with its pinned Helm version.
}

copy_manifests "$SOURCE_DIRECTORY/$REPOSITORY_DIRECTORY/$SOURCE_MANIFESTS_PATH/" "$DESTINATION_DIRECTORY"

# Delete upstream kserve scripts shipped in the manifests directories
find "$DESTINATION_DIRECTORY" -maxdepth 1 -name '*.sh' -delete

update_readme "$MANIFESTS_DIRECTORY" "$SOURCE_TEXT" "$DESTINATION_TEXT"
update_kserve_helm_chart
validate_kserve_helm_chart
# The generated payloads follow the upstream bundle and the component's own
# patches, so both are staged together with the chart files that consume them.
commit_changes "$MANIFESTS_DIRECTORY" "Update ${REPOSITORY_NAME} manifests to version ${COMMIT}" \
    "${MANIFESTS_DIRECTORY}/applications/kserve/kserve/upstream" \
    "${HELM_CHART_PATH}/Chart.yaml" \
    "${HELM_PAYLOAD_CHART_PATH}/Chart.yaml" \
    "${HELM_PAYLOAD_CHART_PATH}/manifests" \
    "${SCRIPT_DIRECTORY}/helm_manifest_generator.py" \
    "${SCRIPT_DIRECTORY}/generate-kserve-helm-manifests.py" \
    "${SCRIPT_DIRECTORY}/synchronize-kserve-kserve-manifests.sh" \
    "${MANIFESTS_DIRECTORY}/README.md"
echo "Synchronization completed successfully."
