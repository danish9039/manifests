#!/usr/bin/env bash
# Lifecycle evidence for the KServe Helm chart: what the chart README claims
# about installation, upgrade, rollback, uninstallation and reinstallation,
# observed on a cluster.
#
# Prerequisites, all installed beforehand: the kserve namespace (the
# kubeflow-namespaces chart), cert-manager, Istio and Knative Serving. No kserve
# release may exist. No workflow runs this script; it needs a cluster of its
# own for about twenty minutes and it uninstalls KServe on the way.
#
# Sequence and resulting release revisions:
#   1, 2  installation from the chart directory (definitions, then everything)
#         an InferenceService is created and a client pod requests a prediction
#         every second until the end of the script
#   3     helm upgrade with the same values file, from UPGRADE_CHART, which
#         defaults to the packaged chart
#   4     helm rollback from revision 3 to revision 2, a full installation
#   -     helm uninstall, then the retention and deletion inventory
#   1, 2  installation from the packaged chart, which adopts the kept
#         definitions, then recovery of reconciliation and of serving
#
# Every request is attributed to a phase by its time, and every phase reports
# its successes, failures and timeouts. Recovery after each operation is
# asserted. Failures during an operation are reported, and fail the script
# only with REQUIRE_SERVING_CONTINUITY=true, because whether the README may
# claim continuity or only recovery is decided from these numbers. An upgrade
# between two identical charts changes nothing in the cluster; point
# UPGRADE_CHART at a chart of another version for a meaningful observation.
#
# The client pod and this script compare clocks, so both must follow the same
# time source, which a local kind cluster does.
set -euo pipefail

SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPOSITORY_ROOT=$(dirname "$SCRIPT_DIRECTORY")
CHART_DIRECTORY="${REPOSITORY_ROOT}/applications/kserve/kserve/helm"
VALUES_FILE="${CHART_DIRECTORY}/ci/values-platform.yaml"
RELEASE_NAME="kserve"
RELEASE_NAMESPACE="kserve"
CUSTOM_RESOURCE_DEFINITION_COUNT=16

TEST_NAMESPACE=${TEST_NAMESPACE:-kserve-lifecycle-test}
INFERENCE_SERVICE_NAME=${INFERENCE_SERVICE_NAME:-lifecycle-sklearn}
CLIENT_POD_NAME="lifecycle-request-client"
CLIENT_IMAGE=${CLIENT_IMAGE:-docker.io/curlimages/curl:8.16.0}
PREDICTION_URL=${PREDICTION_URL:-http://${INFERENCE_SERVICE_NAME}-predictor.${TEST_NAMESPACE}.svc.cluster.local/v1/models/${INFERENCE_SERVICE_NAME}:predict}
REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-5}
OBSERVATION_SECONDS=${OBSERVATION_SECONDS:-30}
REQUIRE_SERVING_CONTINUITY=${REQUIRE_SERVING_CONTINUITY:-false}
EVIDENCE_DIRECTORY=${EVIDENCE_DIRECTORY:-$(mktemp -d)}
TEMPORARY_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT

mkdir -p "$EVIDENCE_DIRECTORY"
SUMMARY_FILE="${EVIDENCE_DIRECTORY}/summary.txt"
PHASES_FILE="${TEMPORARY_DIRECTORY}/phases"
: >"$SUMMARY_FILE"
: >"$PHASES_FILE"

report() {
  echo "$*" | tee -a "$SUMMARY_FILE"
}

fail() {
  report "FAIL: $*"
  exit 1
}

# A phase lasts from its start to the start of the next phase.
start_phase() {
  echo "$(date +%s) $1" >>"$PHASES_FILE"
  report "--- phase $1 started at $(date --utc +%Y-%m-%dT%H:%M:%SZ)"
}

observe() {
  start_phase "$1"
  sleep "$OBSERVATION_SECONDS"
}

custom_resource_definition_names() {
  awk '
    $0 == "kind: CustomResourceDefinition" { definition = 1; next }
    definition && /^  name: / { print $2; definition = 0 }
  ' "$1" | sort
}

deployment_names() {
  awk '
    $0 == "kind: Deployment" { deployment = 1; next }
    deployment && /^  name: / { print $2; deployment = 0 }
  ' "$1"
}

# The two-revision installation of the chart README, from a chart directory or
# from a packaged chart.
install_in_two_revisions() {
  local chart="$1"
  local custom_resource_definition_name
  local deployment_name
  local manifest="${TEMPORARY_DIRECTORY}/installed-manifest.yaml"

  helm install "$RELEASE_NAME" "$chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --values "$VALUES_FILE" \
    --set payload.resources.enabled=false \
    --wait --timeout 5m
  helm get manifest "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" >"$manifest"
  if grep '^kind: ' "$manifest" | grep -qv '^kind: CustomResourceDefinition$'; then
    fail "the first revision renders more than custom resource definitions"
  fi
  for custom_resource_definition_name in $(custom_resource_definition_names "$manifest"); do
    kubectl wait --for=condition=Established \
      "crd/${custom_resource_definition_name}" --timeout=120s
  done

  helm upgrade "$RELEASE_NAME" "$chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --values "$VALUES_FILE" \
    --wait --timeout 10m
  wait_for_the_control_plane
  helm get manifest "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" >"$manifest"
  for deployment_name in $(deployment_names "$manifest"); do
    kubectl rollout status "deployment/${deployment_name}" \
      --namespace "$RELEASE_NAMESPACE" --timeout=300s
  done
}

wait_for_the_control_plane() {
  kubectl wait --for=condition=Ready --namespace "$RELEASE_NAMESPACE" --timeout=120s \
    certificate/serving-cert \
    certificate/llmisvc-serving-cert \
    certificate/localmodel-serving-cert
  kubectl wait --for=condition=Available --namespace "$RELEASE_NAMESPACE" \
    --timeout=300s deployment --all
}

current_revision() {
  helm list --namespace "$RELEASE_NAMESPACE" --filter "^${RELEASE_NAME}\$" --output json |
    python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["revision"])'
}

expect_revision() {
  local revision
  revision=$(current_revision)
  if [[ "$revision" != "$1" ]]; then
    fail "expected release revision $1, found ${revision}"
  fi
  report "release revision ${revision}: $2"
}

create_the_inference_service() {
  kubectl create namespace "$TEST_NAMESPACE" --dry-run=client --output yaml |
    kubectl apply -f -
  # One replica at all times, so that a scale from zero is never mistaken for
  # an interruption.
  kubectl apply -f - <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${INFERENCE_SERVICE_NAME}
  namespace: ${TEST_NAMESPACE}
  annotations:
    autoscaling.knative.dev/min-scale: "1"
spec:
  predictor:
    sklearn:
      storageUri: gs://kfserving-examples/models/sklearn/1.0/model
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          cpu: 100m
          memory: 256Mi
EOF
  kubectl wait --for=condition=Ready "inferenceservice/${INFERENCE_SERVICE_NAME}" \
    --namespace "$TEST_NAMESPACE" --timeout=600s
}

# One line per request: <epoch seconds> <HTTP status> <curl exit status>.
# curl reports the HTTP status 000 when no response arrived and the exit
# status 28 for a timeout.
start_the_request_client() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${CLIENT_POD_NAME}
  namespace: ${TEST_NAMESPACE}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: client
    image: ${CLIENT_IMAGE}
    command:
    - sh
    - -c
    - |
      while true; do
        http_status=\$(curl --silent --output /dev/null --write-out '%{http_code}' \
          --max-time ${REQUEST_TIMEOUT_SECONDS} \
          --header 'Content-Type: application/json' \
          --data '{"instances": [[6.8, 2.8, 4.8, 1.4]]}' \
          '${PREDICTION_URL}')
        curl_status=\$?
        echo "\$(date +%s) \${http_status} \${curl_status}"
        sleep 1
      done
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
      limits:
        cpu: 50m
        memory: 32Mi
EOF
  kubectl wait --for=condition=Ready "pod/${CLIENT_POD_NAME}" \
    --namespace "$TEST_NAMESPACE" --timeout=120s
}

request_log() {
  kubectl logs "pod/${CLIENT_POD_NAME}" --namespace "$TEST_NAMESPACE" \
    >"${EVIDENCE_DIRECTORY}/requests.log"
}

last_request_succeeded() {
  request_log
  [[ "$(tail -n 1 "${EVIDENCE_DIRECTORY}/requests.log" | awk '{print $2}')" == "200" ]]
}

wait_for_a_successful_request() {
  local attempt
  for attempt in $(seq 1 60); do
    if last_request_succeeded; then
      report "a prediction succeeded $1 (attempt ${attempt})"
      return
    fi
    sleep 5
  done
  tail -n 5 "${EVIDENCE_DIRECTORY}/requests.log" | tee -a "$SUMMARY_FILE"
  fail "no prediction succeeded $1 within 300 seconds"
}

# Prints one row per phase and the number of failed or timed out requests in
# the phases named after the first argument.
summarize_requests() {
  request_log
  awk -v phases_file="$PHASES_FILE" -v watched="$1" '
    BEGIN {
      while ((getline line < phases_file) > 0) {
        split(line, fields, " ")
        count++
        start[count] = fields[1]
        name[count] = fields[2]
      }
      printf "%-28s %9s %9s %9s %9s\n", "phase", "requests", "succeeded", "failed", "timed out"
    }
    {
      phase = 0
      for (i = 1; i <= count; i++) if ($1 >= start[i]) phase = i
      if (!phase) next
      total[phase]++
      if ($2 == "200") succeeded[phase]++
      else if ($3 == "28") timed_out[phase]++
      else failed[phase]++
    }
    END {
      for (i = 1; i <= count; i++) {
        printf "%-28s %9d %9d %9d %9d\n", name[i], total[i], succeeded[i], failed[i], timed_out[i]
        if (index(" " watched " ", " " name[i] " ")) interrupted += failed[i] + timed_out[i]
      }
      printf "interrupted %d\n", interrupted
    }
  ' "${EVIDENCE_DIRECTORY}/requests.log"
}

check_the_uninstall_inventory() {
  local manifest="$1"
  local expected="${TEMPORARY_DIRECTORY}/expected-remaining"
  local remaining="${EVIDENCE_DIRECTORY}/remaining-after-uninstall.txt"

  custom_resource_definition_names "$manifest" |
    sed 's|^|customresourcedefinition.apiextensions.k8s.io/|' >"$expected"
  if [[ "$(wc -l <"$expected")" -ne "$CUSTOM_RESOURCE_DEFINITION_COUNT" ]]; then
    fail "the release did not hold ${CUSTOM_RESOURCE_DEFINITION_COUNT} custom resource definitions"
  fi
  # Every object of the uninstalled revision that still exists. The kept
  # definitions let kubectl resolve ClusterServingRuntime and
  # ClusterStorageContainer, so their deletion is observed rather than assumed.
  kubectl get -f "$manifest" --ignore-not-found --output name | sort >"$remaining"
  if ! diff "$expected" "$remaining" | tee -a "$SUMMARY_FILE"; then
    fail "the objects that survived helm uninstall are not exactly the kept definitions"
  fi
  report "kept: $(wc -l <"$remaining") custom resource definitions; deleted: every other object of the release, of $(grep -c '^kind: ' "$manifest") in total"

  if grep -Eq '^kind: (ClusterServingRuntime|ClusterStorageContainer)$' "$manifest"; then
    report "the bundled ClusterServingRuntime and ClusterStorageContainer objects were part of the release and are deleted"
  else
    fail "the release held no bundled ClusterServingRuntime or ClusterStorageContainer"
  fi
  kubectl get "inferenceservice/${INFERENCE_SERVICE_NAME}" --namespace "$TEST_NAMESPACE" \
    --output name || fail "the InferenceService a user created was deleted"
  report "kept: inferenceservice/${INFERENCE_SERVICE_NAME}, created by a user"
}

helm_version=$(helm version --template '{{ .Version }}')
if [[ "$helm_version" != v4.* ]]; then
  fail "Helm 4 is required, found ${helm_version}"
fi
if helm status "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" &>/dev/null; then
  fail "a ${RELEASE_NAME} release already exists; this test installs its own"
fi
kubectl get namespace "$RELEASE_NAMESPACE" cert-manager istio-system knative-serving \
  --output name || fail "a prerequisite namespace is missing"
report "helm ${helm_version}; evidence in ${EVIDENCE_DIRECTORY}"

helm package "$CHART_DIRECTORY" --destination "$TEMPORARY_DIRECTORY"
PACKAGED_CHART=$(find "$TEMPORARY_DIRECTORY" -maxdepth 1 -name 'kserve-*.tgz')
UPGRADE_CHART=${UPGRADE_CHART:-$PACKAGED_CHART}

report "=== installation from the chart directory"
install_in_two_revisions "$CHART_DIRECTORY"
expect_revision 2 "full installation from the chart directory"
create_the_inference_service
start_the_request_client
wait_for_a_successful_request "before any operation"

report "=== upgrade from ${UPGRADE_CHART}"
observe before-upgrade
start_phase during-upgrade
helm upgrade "$RELEASE_NAME" "$UPGRADE_CHART" \
  --namespace "$RELEASE_NAMESPACE" \
  --values "$VALUES_FILE" \
  --wait --timeout 10m
wait_for_the_control_plane
expect_revision 3 "upgrade"
observe after-upgrade
wait_for_a_successful_request "after the upgrade"

report "=== rollback from revision 3 to revision 2"
start_phase during-rollback
helm rollback "$RELEASE_NAME" 2 --namespace "$RELEASE_NAMESPACE" --wait --timeout 10m
wait_for_the_control_plane
expect_revision 4 "rollback to revision 2"
observe after-rollback
wait_for_a_successful_request "after the rollback"

report "=== uninstallation"
helm get manifest "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" \
  >"${EVIDENCE_DIRECTORY}/manifest-before-uninstall.yaml"
start_phase uninstalled-no-promise
helm uninstall "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" --wait --timeout 10m
check_the_uninstall_inventory "${EVIDENCE_DIRECTORY}/manifest-before-uninstall.yaml"
sleep "$OBSERVATION_SECONDS"

report "=== installation from the packaged chart ${PACKAGED_CHART##*/}"
start_phase during-reinstallation
install_in_two_revisions "$PACKAGED_CHART"
expect_revision 2 "full installation from the packaged chart, definitions adopted"
start_phase after-reinstallation
# Reconciliation recovers: the controller accepts a change to the kept object
# and reports it Ready again.
kubectl annotate "inferenceservice/${INFERENCE_SERVICE_NAME}" --namespace "$TEST_NAMESPACE" \
  --overwrite "kserve-lifecycle-test/reconciled-at=$(date +%s)"
kubectl wait --for=condition=Ready "inferenceservice/${INFERENCE_SERVICE_NAME}" \
  --namespace "$TEST_NAMESPACE" --timeout=600s
wait_for_a_successful_request "after the reinstallation"
sleep "$OBSERVATION_SECONDS"

report "=== requests"
summarize_requests "during-upgrade after-upgrade during-rollback after-rollback" |
  tee -a "$SUMMARY_FILE"
interrupted=$(awk '$1 == "interrupted" { print $2 }' "$SUMMARY_FILE")
helm history "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" | tee -a "$SUMMARY_FILE"

kubectl delete "pod/${CLIENT_POD_NAME}" --namespace "$TEST_NAMESPACE" --wait=false
kubectl delete "inferenceservice/${INFERENCE_SERVICE_NAME}" --namespace "$TEST_NAMESPACE" \
  --wait=false

if [[ "$interrupted" -ne 0 ]]; then
  report "serving continuity: NOT observed, ${interrupted} requests failed or timed out across the upgrade and the rollback; the supported claim is recovery"
  if [[ "$REQUIRE_SERVING_CONTINUITY" == "true" ]]; then
    exit 1
  fi
else
  report "serving continuity: observed, no request failed or timed out across the upgrade and the rollback"
fi
report "PASS: installation from the directory and from the package, upgrade, rollback, uninstall inventory and reinstall recovery"
