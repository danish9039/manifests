#!/usr/bin/env bash
# Cluster-free tests of the request accounting in
# tests/kserve_helm_lifecycle_test.sh. The script is sourced, which defines its
# functions without running it, and kubectl is replaced by a function that
# prints a prepared request log. The operation boundaries are the epoch seconds
# 200, 300, 400 and 500; every request line is
# "<epoch seconds> <HTTP status> <curl exit status>".
set -euo pipefail

SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
EVIDENCE_DIRECTORY=$(mktemp -d)
export EVIDENCE_DIRECTORY
export RECOVERY_ATTEMPTS=1
export RECOVERY_INTERVAL_SECONDS=0
# shellcheck source=tests/kserve_helm_lifecycle_test.sh
source "${SCRIPT_DIRECTORY}/kserve_helm_lifecycle_test.sh"
trap 'rm -rf "$TEMPORARY_DIRECTORY" "$EVIDENCE_DIRECTORY"' EXIT
: >"$SUMMARY_FILE"

REQUEST_LOG_FIXTURE=""
FAILED_TESTS=0

# The only kubectl call of the functions under test is "kubectl logs".
kubectl() {
  if [[ "$1" != "logs" ]]; then
    echo "unexpected kubectl call: $*" >&2
    return 1
  fi
  printf '%s' "$REQUEST_LOG_FIXTURE"
}

write_phases() {
  printf '%s\n' \
    "200 during-upgrade" \
    "300 after-upgrade" \
    "400 during-rollback" \
    "500 after-rollback" >"$PHASES_FILE"
}

expect() {
  local description="$1"
  shift
  if "$@"; then
    echo "ok: ${description}"
  else
    echo "FAILED: ${description}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
}

not() {
  ! "$@"
}

summary_row() {
  summarize_requests "$WATCHED_PHASES" | awk -v phase="$1" '$1 == phase { print $2, $3, $4, $5 }'
}

summary_value() {
  summarize_requests "$WATCHED_PHASES" | awk -v key="$1" '$1 == key { print $2 }'
}

continuity_verdict() {
  local requests_summary="${TEMPORARY_DIRECTORY}/requests-summary"
  local status=0
  summarize_requests "$WATCHED_PHASES" >"$requests_summary"
  report_serving_continuity "$requests_summary" >/dev/null || status=$?
  echo "${status} $(tail -n 1 "$SUMMARY_FILE")"
}

continuity_verdict_starts_with() {
  [[ "$(continuity_verdict)" == "$1"* ]]
}

test_a_stale_success_is_not_recovery() {
  REQUEST_LOG_FIXTURE=$'100 200 0\n'
  expect "a success from before the boundary 200 is not recovery" \
    not fresh_request_succeeded 200
  if (wait_for_a_successful_request "after the upgrade" 200) >/dev/null 2>&1; then
    expect "waiting for recovery fails on a stale success" false
  else
    expect "waiting for recovery fails on a stale success" true
  fi

  REQUEST_LOG_FIXTURE=$'100 200 0\n201 200 0\n'
  expect "a success after the boundary 200 is recovery" fresh_request_succeeded 200
  REQUEST_LOG_FIXTURE=$'100 200 0\n200 200 0\n'
  expect "a success in the boundary second itself is not recovery" \
    not fresh_request_succeeded 200
  REQUEST_LOG_FIXTURE=$'201 200 0\n205 503 0\n'
  expect "only the newest request counts as recovery" not fresh_request_succeeded 200
}

test_a_timed_out_transfer_is_not_a_success() {
  write_phases
  REQUEST_LOG_FIXTURE=$'210 200 0\n310 200 0\n410 200 0\n510 200 28\n'
  expect "510 200 28 is a timeout, not a success" \
    test "$(summary_row after-rollback)" == "1 0 0 1"
  expect "510 200 28 interrupts serving" test "$(summary_value interrupted)" == "1"
  expect "continuity is not observed with a timeout" \
    continuity_verdict_starts_with "1 serving continuity: NOT observed"
  expect "a fresh 510 200 28 is not recovery" not fresh_request_succeeded 500

  REQUEST_LOG_FIXTURE=$'210 200 0\n310 200 7\n410 000 7\n510 503 0\n'
  expect "a transport failure with HTTP 200 is a failure" \
    test "$(summary_row after-upgrade)" == "1 0 1 0"
  expect "an HTTP error with curl exit 0 is a failure" \
    test "$(summary_row after-rollback)" == "1 0 1 0"
  expect "three requests interrupted serving" test "$(summary_value interrupted)" == "3"
}

test_an_empty_phase_is_inconclusive() {
  write_phases
  REQUEST_LOG_FIXTURE=$'210 200 0\n310 200 0\n510 200 0\n'
  expect "the phase during-rollback holds no request" \
    test "$(summary_row during-rollback)" == "0 0 0 0"
  expect "one watched phase is inconclusive" test "$(summary_value inconclusive)" == "1"
  expect "continuity is inconclusive, not observed, with an empty phase" \
    continuity_verdict_starts_with "1 serving continuity: INCONCLUSIVE"

  REQUEST_LOG_FIXTURE=""
  expect "no request at all leaves four phases inconclusive" \
    test "$(summary_value inconclusive)" == "4"
  expect "continuity is inconclusive without any request" \
    continuity_verdict_starts_with "1 serving continuity: INCONCLUSIVE"

  REQUEST_LOG_FIXTURE=$'210 200 0\n310 200 0\n410 200 0\n510 200 0\n'
  expect "continuity is observed when every watched phase succeeded" \
    continuity_verdict_starts_with "0 serving continuity: observed"
}

test_a_stale_success_is_not_recovery
test_a_timed_out_transfer_is_not_a_success
test_an_empty_phase_is_inconclusive

if [[ "$FAILED_TESTS" -ne 0 ]]; then
  echo "${FAILED_TESTS} checks failed"
  exit 1
fi
echo "all checks passed"
