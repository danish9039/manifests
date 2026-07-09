#!/usr/bin/env bash
# Template for Kubeflow manifests synchronization scripts
# Usage: Copy this file and adjust the variables for your specific component
# Source the common library functions
SCRIPT_DIRECTORY=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIRECTORY}/library.sh"
setup_error_handling
# Configuration variables (adjust these for your specific component)
COMPONENT_NAME="component-name"  # Name of the component (e.g., katib, trainer)
REPOSITORY_NAME="repository-name"      # Repository name (e.g., kubeflow/katib)
REPOSITORY_URL="https://github.com/organization/repository.git"  # Repository URL to clone from
COMMIT="v0.0.0"                  # Version/commit to synchronize
REPOSITORY_DIRECTORY="${COMPONENT_NAME}"     # Directory name within SOURCE_DIRECTORY
SOURCE_DIRECTORY=${SOURCE_DIRECTORY:=/tmp/kubeflow-${COMPONENT_NAME}}  # Where to clone the source repository
BRANCH_NAME=${BRANCH_NAME:=synchronize-${COMPONENT_NAME}-manifests-${COMMIT?}}  # Branch name for the pull request
MANIFESTS_DIRECTORY=$(dirname $SCRIPT_DIRECTORY)
SOURCE_MANIFESTS_PATH="manifests"   # Path within source repository where manifests are
DESTINATION_MANIFESTS_PATH="applications/${COMPONENT_NAME}/upstream"  # Destination path within manifests repository
SOURCE_TEXT="\[.*\](https://github.com/${REPOSITORY_NAME}/tree/.*/manifests)"
DESTINATION_TEXT="\[${COMMIT}\](https://github.com/${REPOSITORY_NAME}/tree/${COMMIT}/manifests)"
create_branch "$BRANCH_NAME"
clone_and_checkout "$SOURCE_DIRECTORY" "$REPOSITORY_URL" "$REPOSITORY_DIRECTORY" "$COMMIT"
copy_manifests "${SOURCE_DIRECTORY}/${REPOSITORY_DIRECTORY}/${SOURCE_MANIFESTS_PATH}" "${MANIFESTS_DIRECTORY}/${DESTINATION_MANIFESTS_PATH}"
update_readme "$MANIFESTS_DIRECTORY" "$SOURCE_TEXT" "$DESTINATION_TEXT"
commit_changes "$MANIFESTS_DIRECTORY" "Update ${REPOSITORY_NAME} manifests from ${COMMIT}" "$MANIFESTS_DIRECTORY"
echo "Synchronization completed successfully." 
