#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: check-drift.sh <scenario-name>

Checks Helm/Kustomize drift for one Project 5 scenario by:
  1. Rendering the chart from the current checkout
  2. Building the Kustomize baseline from a temporary master worktree
  3. Comparing both outputs with the existing compare harness

Supported scenarios:
  - platform-agnostic-multi-user
  - platform-agnostic-multi-user-k8s-native
  - standalone
  - cert-manager
  - external-db
  - leader-election
  - openshift
  - standalone-postgres
  - with-kubeflow

Optional environment variables:
  DRIFT_BASE_REF          Git ref for baseline checkout (default: origin/master)
  DRIFT_RESULTS_DIR       Directory for JSON result output
  KUSTOMIZE_GIT_TIMEOUT   Timeout for remote Kustomize git fetches (default: 180s)
  VERBOSE                 If non-empty, pass --verbose to the compare script
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
COMPARE_SCRIPT="${REPO_ROOT}/tests/helm_kustomize_compare.py"

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

SCENARIO="$1"
BASE_REF="${DRIFT_BASE_REF:-origin/master}"
: "${KUSTOMIZE_GIT_TIMEOUT:=180s}"
export KUSTOMIZE_GIT_TIMEOUT

for required_command in git helm kustomize python3; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "ERROR: ${required_command} is required but not installed or not on PATH" >&2
        exit 1
    fi
done

if [[ ! -f "${COMPARE_SCRIPT}" ]]; then
    echo "ERROR: compare script not found: ${COMPARE_SCRIPT}" >&2
    exit 1
fi

COMPONENT=""
COMPARE_SCENARIO=""
CHART_DIR=""
VALUES_FILE=""
KUSTOMIZE_PATH_REL=""
NAMESPACE="kubeflow"
RELEASE_NAME=""

case "${SCENARIO}" in
    platform-agnostic-multi-user)
        COMPONENT="pipelines"
        COMPARE_SCENARIO="platform-agnostic-multi-user"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/pipelines"
        VALUES_FILE="${CHART_DIR}/ci/values-platform-agnostic-multi-user.yaml"
        KUSTOMIZE_PATH_REL="applications/pipeline/upstream/env/cert-manager/platform-agnostic-multi-user"
        RELEASE_NAME="pipeline"
        ;;
    platform-agnostic-multi-user-k8s-native)
        COMPONENT="pipelines"
        COMPARE_SCENARIO="platform-agnostic-multi-user-k8s-native"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/pipelines"
        VALUES_FILE="${CHART_DIR}/ci/values-platform-agnostic-multi-user-k8s-native.yaml"
        KUSTOMIZE_PATH_REL="applications/pipeline/upstream/env/cert-manager/platform-agnostic-multi-user-k8s-native"
        RELEASE_NAME="pipeline"
        ;;
    standalone)
        COMPONENT="katib"
        COMPARE_SCENARIO="standalone"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/katib"
        VALUES_FILE="${CHART_DIR}/ci/values-standalone.yaml"
        KUSTOMIZE_PATH_REL="applications/katib/upstream/installs/katib-standalone"
        RELEASE_NAME="katib"
        ;;
    cert-manager)
        COMPONENT="katib"
        COMPARE_SCENARIO="cert-manager"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/katib"
        VALUES_FILE="${CHART_DIR}/ci/values-cert-manager.yaml"
        KUSTOMIZE_PATH_REL="applications/katib/upstream/installs/katib-cert-manager"
        RELEASE_NAME="katib"
        ;;
    external-db)
        COMPONENT="katib"
        COMPARE_SCENARIO="external-db"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/katib"
        VALUES_FILE="${CHART_DIR}/ci/values-external-db.yaml"
        KUSTOMIZE_PATH_REL="applications/katib/upstream/installs/katib-external-db"
        RELEASE_NAME="katib"
        ;;
    leader-election)
        COMPONENT="katib"
        COMPARE_SCENARIO="leader-election"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/katib"
        VALUES_FILE="${CHART_DIR}/ci/values-leader-election.yaml"
        KUSTOMIZE_PATH_REL="applications/katib/upstream/installs/katib-leader-election"
        RELEASE_NAME="katib"
        ;;
    openshift)
        COMPONENT="katib"
        COMPARE_SCENARIO="openshift"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/katib"
        VALUES_FILE="${CHART_DIR}/ci/values-openshift.yaml"
        KUSTOMIZE_PATH_REL="applications/katib/upstream/installs/katib-openshift"
        RELEASE_NAME="katib"
        ;;
    standalone-postgres)
        COMPONENT="katib"
        COMPARE_SCENARIO="standalone-postgres"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/katib"
        VALUES_FILE="${CHART_DIR}/ci/values-postgres.yaml"
        KUSTOMIZE_PATH_REL="applications/katib/upstream/installs/katib-standalone-postgres"
        RELEASE_NAME="katib"
        ;;
    with-kubeflow)
        COMPONENT="katib"
        COMPARE_SCENARIO="with-kubeflow"
        CHART_DIR="${REPO_ROOT}/experimental/helm/charts/katib"
        VALUES_FILE="${CHART_DIR}/ci/values-kubeflow.yaml"
        KUSTOMIZE_PATH_REL="applications/katib/upstream/installs/katib-with-kubeflow"
        RELEASE_NAME="katib"
        ;;
    *)
        echo "ERROR: Unsupported scenario: ${SCENARIO}" >&2
        usage
        exit 1
        ;;
esac

if [[ ! -d "${CHART_DIR}" ]]; then
    echo "ERROR: chart directory not found: ${CHART_DIR}" >&2
    exit 1
fi

if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "ERROR: values file not found: ${VALUES_FILE}" >&2
    exit 1
fi

if ! git -C "${REPO_ROOT}" rev-parse --verify "${BASE_REF}" >/dev/null 2>&1; then
    if [[ "${BASE_REF}" == "origin/master" ]]; then
        git -C "${REPO_ROOT}" fetch origin master --quiet
    fi
fi

if ! git -C "${REPO_ROOT}" rev-parse --verify "${BASE_REF}" >/dev/null 2>&1; then
    echo "ERROR: baseline ref does not exist: ${BASE_REF}" >&2
    exit 1
fi

BASELINE_WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/helm-drift-${SCENARIO}-XXXXXX")"
KUSTOMIZE_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/kustomize-${SCENARIO}-XXXXXX.yaml")"
HELM_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/helm-${SCENARIO}-XXXXXX.yaml")"
COMPARE_LOG="$(mktemp "${TMPDIR:-/tmp}/compare-${SCENARIO}-XXXXXX.log")"

cleanup() {
    rm -f "${KUSTOMIZE_OUTPUT}" "${HELM_OUTPUT}" "${COMPARE_LOG}"
    if [[ -d "${BASELINE_WORKTREE}" ]]; then
        git -C "${REPO_ROOT}" worktree remove --force "${BASELINE_WORKTREE}" >/dev/null 2>&1 || rm -rf "${BASELINE_WORKTREE}"
    fi
}
trap cleanup EXIT

write_result_file() {
    local destination="$1"
    python3 - <<'PY' "${destination}" "${SCENARIO}" "${COMPONENT}" "${COMPARE_SCENARIO}" "${BASE_REF}" "${RESULT}" "${SUMMARY}" "${EXCERPT}"
import json
import sys

destination, scenario, component, compare_scenario, base_ref, result, summary, excerpt = sys.argv[1:]
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "scenario": scenario,
            "component": component,
            "compare_scenario": compare_scenario,
            "base_ref": base_ref,
            "result": result,
            "summary": summary,
            "excerpt": excerpt,
        },
        handle,
        indent=2,
    )
PY
}

echo "==> Scenario: ${SCENARIO}"
echo "==> Component: ${COMPONENT}"
echo "==> Baseline ref: ${BASE_REF}"

git -C "${REPO_ROOT}" worktree add --detach "${BASELINE_WORKTREE}" "${BASE_REF}" >/dev/null

KUSTOMIZE_PATH="${BASELINE_WORKTREE}/${KUSTOMIZE_PATH_REL}"
if [[ ! -d "${KUSTOMIZE_PATH}" ]]; then
    echo "ERROR: baseline Kustomize path not found: ${KUSTOMIZE_PATH}" >&2
    exit 1
fi

echo "==> Building Kustomize baseline from ${KUSTOMIZE_PATH_REL}"
kustomize build "${KUSTOMIZE_PATH}" > "${KUSTOMIZE_OUTPUT}"

echo "==> Rendering Helm chart from current checkout"
helm template "${RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    --include-crds \
    --values "${VALUES_FILE}" > "${HELM_OUTPUT}"

echo "==> Comparing rendered outputs"
set +e
python3 "${COMPARE_SCRIPT}" \
    "${KUSTOMIZE_OUTPUT}" \
    "${HELM_OUTPUT}" \
    "${COMPONENT}" \
    "${COMPARE_SCENARIO}" \
    "${NAMESPACE}" \
    ${VERBOSE:+--verbose} 2>&1 | tee "${COMPARE_LOG}"
COMPARE_EXIT=${PIPESTATUS[0]}
set -e

SUMMARY="$(grep -E 'Found differences in [0-9]+ resources' "${COMPARE_LOG}" | tail -n 1 || true)"
if [[ -z "${SUMMARY}" ]]; then
    if [[ ${COMPARE_EXIT} -eq 0 ]]; then
        SUMMARY="No drift detected"
    else
        SUMMARY="Drift detected; see log artifact for details"
    fi
fi

EXCERPT="$(python3 - <<'PY' "${COMPARE_LOG}" "${COMPARE_EXIT}"
from pathlib import Path
import re
import sys

log_path = Path(sys.argv[1])
exit_code = int(sys.argv[2])
text = log_path.read_text(encoding="utf-8")
if exit_code == 0:
    print("No drift detected")
    raise SystemExit(0)

matches = []
for line in text.splitlines():
    if re.search(r"Found differences in|Resources only in Kustomize|Unexpected resources only in Helm|Differences in ", line):
        matches.append(line.strip())
        if len(matches) == 6:
            break
if not matches:
    matches = [text.strip().splitlines()[-1] if text.strip() else "Drift detected"]
print(" | ".join(matches))
PY
)"

RESULT="PASS"
if [[ ${COMPARE_EXIT} -ne 0 ]]; then
    RESULT="FAIL"
fi

if [[ -n "${DRIFT_RESULTS_DIR:-}" ]]; then
    mkdir -p "${DRIFT_RESULTS_DIR}"
    write_result_file "${DRIFT_RESULTS_DIR}/${SCENARIO}.json"
fi

echo "==> Summary: ${SUMMARY}"
if [[ ${COMPARE_EXIT} -eq 0 ]]; then
    echo "==> Overall result: PASS"
    exit 0
fi

echo "==> Drift excerpt: ${EXCERPT}"
echo "==> Overall result: FAIL"
exit 1
