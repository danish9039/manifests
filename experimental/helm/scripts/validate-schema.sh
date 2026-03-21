#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: validate-schema.sh <chart-path> <values-file>

Runs:
  1. helm lint <chart-path> -f <values-file>
  2. helm template kubeflow-validate <chart-path> -f <values-file> | kubeconform ...

Optional environment variables:
  SCHEMA_VALIDATION_SCENARIO     Human-readable scenario label for CI summaries
  SCHEMA_VALIDATION_SCENARIO_ID  File-safe scenario identifier for CI artifacts
  SCHEMA_VALIDATION_RESULTS_DIR  Directory for JSON result output
  HELM_SCHEMA_RELEASE_NAME       Helm release name override (default: kubeflow-validate)
  KUBERNETES_VERSION             kubeconform kubernetes version (default: 1.29.0)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

resolve_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "${REPO_ROOT}/${path}"
    fi
}

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
    echo "ERROR: helm is required but not installed or not on PATH" >&2
    exit 1
fi

if ! command -v kubeconform >/dev/null 2>&1; then
    echo "ERROR: kubeconform is required but not installed or not on PATH" >&2
    exit 1
fi

CHART_PATH="$(resolve_path "$1")"
VALUES_FILE="$(resolve_path "$2")"
RELEASE_NAME="${HELM_SCHEMA_RELEASE_NAME:-kubeflow-validate}"
KUBE_VERSION="${KUBERNETES_VERSION:-1.29.0}"
SCENARIO_LABEL="${SCHEMA_VALIDATION_SCENARIO:-$(basename "${VALUES_FILE}" .yaml)}"
SCENARIO_LABEL="${SCENARIO_LABEL#values-}"
SCENARIO_ID="${SCHEMA_VALIDATION_SCENARIO_ID:-${SCENARIO_LABEL}}"
SCENARIO_ID="${SCENARIO_ID//\//-}"
RESULTS_DIR="${SCHEMA_VALIDATION_RESULTS_DIR:-}"

if [[ ! -d "${CHART_PATH}" ]]; then
    echo "ERROR: chart path does not exist: ${CHART_PATH}" >&2
    exit 1
fi

if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "ERROR: values file does not exist: ${VALUES_FILE}" >&2
    exit 1
fi

LINT_LOG="$(mktemp)"
KUBECONFORM_LOG="$(mktemp)"
RENDERED_MANIFESTS="$(mktemp)"

cleanup() {
    rm -f "${LINT_LOG}" "${KUBECONFORM_LOG}" "${RENDERED_MANIFESTS}"
}
trap cleanup EXIT

write_result_file() {
    local destination="$1"
    python3 - <<'PY' "${destination}" "${SCENARIO_LABEL}" "${SCENARIO_ID}" "${CHART_PATH}" "${VALUES_FILE}" "${LINT_RESULT}" "${KUBECONFORM_RESULT}" "${KUBECONFORM_SUMMARY}"
import json
import sys

destination, scenario, scenario_id, chart_path, values_file, lint_result, kube_result, kube_summary = sys.argv[1:]
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "scenario": scenario,
            "scenario_id": scenario_id,
            "chart_path": chart_path,
            "values_file": values_file,
            "lint_result": lint_result,
            "kubeconform_result": kube_result,
            "kubeconform_summary": kube_summary,
        },
        handle,
        indent=2,
    )
PY
}

LINT_RESULT="FAIL"
KUBECONFORM_RESULT="FAIL"
KUBECONFORM_SUMMARY="not run"
OVERALL_EXIT_CODE=0

echo "==> Scenario: ${SCENARIO_LABEL}"
echo "==> Chart: ${CHART_PATH}"
echo "==> Values: ${VALUES_FILE}"
echo

echo "==> Step 1/2: helm lint"
set +e
helm lint "${CHART_PATH}" -f "${VALUES_FILE}" 2>&1 | tee "${LINT_LOG}"
LINT_EXIT_CODE=${PIPESTATUS[0]}
set -e

if [[ ${LINT_EXIT_CODE} -eq 0 ]]; then
    if grep -qi "warning" "${LINT_LOG}"; then
        LINT_RESULT="WARN"
        echo "==> Step 1/2 result: PASS WITH WARNINGS"
    else
        LINT_RESULT="PASS"
        echo "==> Step 1/2 result: PASS"
    fi
else
    LINT_RESULT="FAIL"
    OVERALL_EXIT_CODE=1
    echo "==> Step 1/2 result: FAIL"
fi

echo
echo "==> Step 2/2: helm template | kubeconform"
set +e
helm template "${RELEASE_NAME}" "${CHART_PATH}" -f "${VALUES_FILE}" \
    | tee "${RENDERED_MANIFESTS}" \
    | kubeconform \
        -kubernetes-version "${KUBE_VERSION}" \
        -strict \
        -ignore-missing-schemas \
        -summary 2>&1 | tee "${KUBECONFORM_LOG}"
KUBECONFORM_EXIT_CODE=$?
set -e

KUBECONFORM_SUMMARY="$(grep 'Summary:' "${KUBECONFORM_LOG}" | tail -n 1 || true)"
if [[ -z "${KUBECONFORM_SUMMARY}" ]]; then
    if [[ ${KUBECONFORM_EXIT_CODE} -ne 0 ]]; then
        KUBECONFORM_SUMMARY="summary unavailable (render or schema validation failed)"
    else
        KUBECONFORM_SUMMARY="summary unavailable"
    fi
fi

if [[ ${KUBECONFORM_EXIT_CODE} -eq 0 ]]; then
    KUBECONFORM_RESULT="PASS"
    echo "==> Step 2/2 result: PASS"
else
    KUBECONFORM_RESULT="FAIL"
    OVERALL_EXIT_CODE=1
    echo "==> Step 2/2 result: FAIL"
fi

echo
echo "==> kubeconform summary: ${KUBECONFORM_SUMMARY}"

if [[ -n "${RESULTS_DIR}" ]]; then
    mkdir -p "${RESULTS_DIR}"
    write_result_file "${RESULTS_DIR}/${SCENARIO_ID}.json"
fi

if [[ ${OVERALL_EXIT_CODE} -eq 0 ]]; then
    echo "==> Overall result: PASS"
else
    echo "==> Overall result: FAIL"
fi

exit "${OVERALL_EXIT_CODE}"
