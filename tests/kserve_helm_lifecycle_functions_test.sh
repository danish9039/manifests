#!/usr/bin/env bash
# Cluster-free tests of the request accounting in
# tests/kserve_helm_lifecycle_test.sh. The script is sourced, which defines its
# functions without running it, and kubectl is replaced by a function that
# prints a prepared request log. The phase before-upgrade starts at the epoch
# second 100 and the operation boundaries are the epoch seconds 200, 300, 400
# and 500; every request line is
# "<start epoch second> <completion epoch second> <HTTP status> <curl exit status>".
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
    "100 before-upgrade" \
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

summarize_requests_status() {
  local status=0
  summarize_requests "$WATCHED_PHASES" >/dev/null 2>&1 || status=$?
  echo "$status"
}

# 0: fresh and successful, 1: not so, 2: the request log holds a rejected line.
fresh_request_status() {
  local status=0
  fresh_request_succeeded "$1" >/dev/null 2>&1 || status=$?
  echo "$status"
}

waiting_for_recovery_fails() {
  ! (wait_for_a_successful_request "after the upgrade" "$1") >/dev/null 2>&1
}

continuity_verdict() {
  local requests_summary="${TEMPORARY_DIRECTORY}/requests-summary"
  local status=0
  summarize_requests "$WATCHED_PHASES" >"$requests_summary" 2>/dev/null || true
  report_serving_continuity "$requests_summary" >/dev/null || status=$?
  echo "${status} $(tail -n 1 "$SUMMARY_FILE")"
}

continuity_verdict_starts_with() {
  [[ "$(continuity_verdict)" == "$1"* ]]
}

test_a_stale_success_is_not_recovery() {
  REQUEST_LOG_FIXTURE=$'100 100 200 0\n'
  expect "a success from before the boundary 200 is not recovery" \
    not fresh_request_succeeded 200
  expect "waiting for recovery fails on a stale success" waiting_for_recovery_fails 200

  REQUEST_LOG_FIXTURE=$'100 100 200 0\n201 201 200 0\n'
  expect "a success after the boundary 200 is recovery" fresh_request_succeeded 200
  REQUEST_LOG_FIXTURE=$'100 100 200 0\n200 200 200 0\n'
  expect "a success in the boundary second itself is not recovery" \
    not fresh_request_succeeded 200
  REQUEST_LOG_FIXTURE=$'201 201 200 0\n205 205 503 0\n'
  expect "only the newest request counts as recovery" not fresh_request_succeeded 200
}

test_a_timed_out_transfer_is_not_a_success() {
  write_phases
  REQUEST_LOG_FIXTURE=$'210 210 200 0\n310 310 200 0\n410 410 200 0\n510 515 200 28\n'
  expect "510 515 200 28 is a timeout, not a success" \
    test "$(summary_row after-rollback)" == "1 0 0 1"
  expect "510 515 200 28 interrupts serving" test "$(summary_value interrupted)" == "1"
  expect "continuity is not observed with a timeout" \
    continuity_verdict_starts_with "1 serving continuity: NOT observed"
  expect "a fresh 510 515 200 28 is not recovery" not fresh_request_succeeded 500

  REQUEST_LOG_FIXTURE=$'210 210 200 0\n310 310 200 7\n410 410 000 7\n510 510 503 0\n'
  expect "a transport failure with HTTP 200 is a failure" \
    test "$(summary_row after-upgrade)" == "1 0 1 0"
  expect "an HTTP error with curl exit 0 is a failure" \
    test "$(summary_row after-rollback)" == "1 0 1 0"
  expect "three requests interrupted serving" test "$(summary_value interrupted)" == "3"
}

test_an_empty_phase_is_inconclusive() {
  write_phases
  REQUEST_LOG_FIXTURE=$'210 210 200 0\n310 310 200 0\n510 510 200 0\n'
  expect "no request started in the phase during-rollback" \
    test "$(summary_row during-rollback)" == "0 0 0 0"
  expect "one watched phase is inconclusive" test "$(summary_value inconclusive)" == "1"
  expect "continuity is inconclusive, not observed, with an empty phase" \
    continuity_verdict_starts_with "1 serving continuity: INCONCLUSIVE"

  REQUEST_LOG_FIXTURE=""
  expect "no request at all leaves four phases inconclusive" \
    test "$(summary_value inconclusive)" == "4"
  expect "continuity is inconclusive without any request" \
    continuity_verdict_starts_with "1 serving continuity: INCONCLUSIVE"

  REQUEST_LOG_FIXTURE=$'210 210 200 0\n310 310 200 0\n410 410 200 0\n510 510 200 0\n'
  expect "continuity is observed when every watched phase succeeded" \
    continuity_verdict_starts_with "0 serving continuity: observed"
}

# The completion time alone does not prove that a request was initiated after
# the operation ended.
test_a_request_that_started_before_the_boundary_is_not_recovery() {
  REQUEST_LOG_FIXTURE=$'199 203 200 0\n'
  expect "a success that started before the boundary 200 and completed after it is not recovery" \
    test "$(fresh_request_status 200)" == "1"
  expect "waiting for recovery fails on a success that only completed after the boundary" \
    waiting_for_recovery_fails 200
  REQUEST_LOG_FIXTURE=$'200 203 200 0\n'
  expect "a success that started in the boundary second and completed after it is not recovery" \
    test "$(fresh_request_status 200)" == "1"
  REQUEST_LOG_FIXTURE=$'199 203 200 0\n201 204 200 0\n'
  expect "a success that started after the boundary 200 is recovery" \
    test "$(fresh_request_status 200)" == "0"
}

test_a_crossing_request_belongs_to_the_phase_in_which_it_started() {
  write_phases
  REQUEST_LOG_FIXTURE=$'150 150 200 0\n198 202 200 0\n210 210 200 0\n310 310 200 0\n410 410 200 0\n510 510 200 0\n'
  expect "198 202 200 0 is counted in before-upgrade, where it started" \
    test "$(summary_row before-upgrade)" == "2 2 0 0"
  expect "198 202 200 0 is not counted in during-upgrade, where it completed" \
    test "$(summary_row during-upgrade)" == "1 1 0 0"
  expect "198 202 200 0 crossed the boundary before-upgrade->during-upgrade" \
    test "$(summary_row "before-upgrade->during-upgrade")" == "1 1 0 0"
  expect "no request crossed the boundary during-upgrade->after-upgrade" \
    test "$(summary_row "during-upgrade->after-upgrade")" == "0 0 0 0"
  expect "one request crossed a boundary" test "$(summary_value crossed)" == "1"
  expect "a crossing request that succeeded does not interrupt serving" \
    test "$(summary_value interrupted)" == "0"
  expect "continuity is observed with a crossing request that succeeded" \
    continuity_verdict_starts_with "0 serving continuity: observed"

  REQUEST_LOG_FIXTURE=$'198 302 200 0\n310 310 200 0\n410 410 200 0\n510 510 200 0\n'
  expect "a request that spans during-upgrade crossed both of its boundaries" \
    test "$(summary_row "before-upgrade->during-upgrade") $(summary_row "during-upgrade->after-upgrade")" == "1 1 0 0 1 1 0 0"
  expect "a request that crossed two boundaries is one crossing request" \
    test "$(summary_value crossed)" == "1"
  expect "a phase that requests only crossed is inconclusive" \
    test "$(summary_row during-upgrade) $(summary_value inconclusive)" == "0 0 0 0 1"
}

test_a_crossing_request_that_failed_is_an_interruption() {
  write_phases
  REQUEST_LOG_FIXTURE=$'198 203 000 28\n210 210 200 0\n310 310 200 0\n410 410 200 0\n510 510 200 0\n'
  expect "198 203 000 28 is a timeout of before-upgrade, where it started" \
    test "$(summary_row before-upgrade)" == "1 0 0 1"
  expect "198 203 000 28 is not a timeout of during-upgrade" \
    test "$(summary_row during-upgrade)" == "1 1 0 0"
  expect "198 203 000 28 timed out over the boundary before-upgrade->during-upgrade" \
    test "$(summary_row "before-upgrade->during-upgrade")" == "1 0 0 1"
  expect "a timeout that crossed into the upgrade interrupts serving" \
    test "$(summary_value interrupted)" == "1"
  expect "continuity is not observed with a timeout that crossed into the upgrade" \
    continuity_verdict_starts_with "1 serving continuity: NOT observed"

  REQUEST_LOG_FIXTURE=$'199 201 503 0\n210 210 200 0\n310 310 200 0\n410 410 200 0\n510 510 200 0\n'
  expect "an HTTP error that crossed into the upgrade interrupts serving" \
    test "$(summary_row "before-upgrade->during-upgrade") $(summary_value interrupted)" == "1 0 1 0 1"
  REQUEST_LOG_FIXTURE=$'150 150 503 0\n210 210 200 0\n310 310 200 0\n410 410 200 0\n510 510 200 0\n'
  expect "a failure that started and completed before the upgrade does not interrupt it" \
    test "$(summary_row before-upgrade) $(summary_value interrupted)" == "1 0 1 0 0"
  REQUEST_LOG_FIXTURE=$'398 402 000 7\n'
  expect "a failure that crossed from one watched phase into the next is one interruption" \
    test "$(summary_row after-upgrade) $(summary_value interrupted)" == "1 0 1 0 1"

  printf '%s\n' "200 during-upgrade" "300 after-upgrade" >"$PHASES_FILE"
  REQUEST_LOG_FIXTURE=$'150 150 503 0\n195 203 000 7\n210 210 200 0\n310 310 200 0\n'
  expect "a failure that started before the first phase and completed in the upgrade interrupts serving" \
    test "$(summary_row "before-the-first-phase->during-upgrade") $(summary_value interrupted)" == "1 0 1 0 1"
}

# A rejected line is never counted: not as a request, and not as recovery.
test_a_malformed_request_log_is_rejected() {
  local malformed_line
  write_phases

  # The format before the start of a request was recorded.
  REQUEST_LOG_FIXTURE=$'201 200 0\n'
  expect "the old line format 201 200 0 is rejected, not taken for recovery" \
    test "$(fresh_request_status 200)" == "2"
  : >"$SUMMARY_FILE"
  expect "waiting for recovery fails on a rejected line" waiting_for_recovery_fails 200
  expect "the rejected line and the failure are reported" \
    test "$(grep -c -e '^rejected line 1 of the request log: 201 200 0$' -e '^FAIL: the request log holds rejected lines' "$SUMMARY_FILE")" == "2"

  for malformed_line in "310 200 0" "310 312 200 0 0" "312 310 200 0" "310 312 OK 0" \
    "310 312 200" "310 312 20 0" "310 312 200 -1" "310.5 312 200 0" "310 312.5 200 0" "curl: (6) no host"; do
    REQUEST_LOG_FIXTURE=$'210 210 200 0\n310 310 200 0\n'"${malformed_line}"$'\n410 410 200 0\n510 510 200 0\n'
    expect "summarizing fails on the line \"${malformed_line}\"" \
      test "$(summarize_requests_status)" == "1"
    expect "no request is counted next to the line \"${malformed_line}\"" \
      test "$(summarize_requests "$WATCHED_PHASES" 2>/dev/null | wc -l)" == "0"
    expect "a rejected line is not recovery even under a fresh success, with \"${malformed_line}\"" \
      test "$(fresh_request_status 500)" == "2"
  done
  expect "the rejected line is named on standard error" \
    test "$(summarize_requests "$WATCHED_PHASES" 2>&1 >/dev/null)" == "rejected line 3 of the request log: curl: (6) no host"
  expect "continuity is inconclusive with a rejected line between successes in every watched phase" \
    continuity_verdict_starts_with "1 serving continuity: INCONCLUSIVE"
}

test_a_stale_success_is_not_recovery
test_a_timed_out_transfer_is_not_a_success
test_an_empty_phase_is_inconclusive
test_a_request_that_started_before_the_boundary_is_not_recovery
test_a_crossing_request_belongs_to_the_phase_in_which_it_started
test_a_crossing_request_that_failed_is_an_interruption
test_a_malformed_request_log_is_rejected

if [[ "$FAILED_TESTS" -ne 0 ]]; then
  echo "${FAILED_TESTS} checks failed"
  exit 1
fi
echo "all checks passed"
