#!/usr/bin/env bash
# Lifecycle evidence for the Spark Operator Helm chart. It is run by hand on a
# cluster where tests/spark_helm_install.sh has installed the release and a
# Profile namespace exists; it is not part of any workflow.
#
# It proves what `helm uninstall` and a later `helm install` do:
#   - the three custom resource definitions and a user SparkApplication with
#     the same UID remain after the uninstallation;
#   - the operator workloads and the three aggregated ClusterRoles are deleted;
#   - after the reinstallation the operator reconciles again: a new
#     SparkApplication completes and the retained one is observed.
# It makes no claim that a running application continues without the operator.
set -euxo pipefail

NAMESPACE=$1
REPOSITORY_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "${GITHUB_WORKSPACE:-$(pwd)}")
cd "${REPOSITORY_ROOT}"

SPARK_APPLICATION_YAML="applications/spark/sparkapplication_example.yaml"
RETAINED_APPLICATION="spark-pi-python"
# The name must not contain the retained name, because step 7 searches the
# controller log for the retained name.
NEW_APPLICATION="reinstallation-spark-pi"
CUSTOM_RESOURCE_DEFINITIONS=(
  scheduledsparkapplications.sparkoperator.k8s.io
  sparkapplications.sparkoperator.k8s.io
  sparkconnects.sparkoperator.k8s.io
)
AGGREGATED_ROLES=(kubeflow-spark-admin kubeflow-spark-edit kubeflow-spark-view)
OPERATOR_DEPLOYMENTS=(spark-operator-controller spark-operator-webhook)

wait_for_application_state() {
  local application="$1"
  local expected="$2"
  local state=""
  for _ in $(seq 1 120); do
    state=$(kubectl -n "${NAMESPACE}" get sparkapplication "${application}" \
      -o jsonpath='{.status.applicationState.state}')
    if [[ "${state}" == "${expected}" ]]; then
      return 0
    fi
    if [[ "${state}" == "FAILED" ]]; then
      break
    fi
    sleep 5
  done
  echo "ERROR: SparkApplication ${application} is ${state:-without a state}, expected ${expected}." >&2
  kubectl -n "${NAMESPACE}" describe sparkapplication "${application}" >&2
  return 1
}

definition_identifiers() {
  kubectl get customresourcedefinitions "${CUSTOM_RESOURCE_DEFINITIONS[@]}" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{"\n"}{end}'
}

cleanup() {
  kubectl -n "${NAMESPACE}" delete sparkapplication \
    "${RETAINED_APPLICATION}" "${NEW_APPLICATION}" --ignore-not-found
}
trap cleanup EXIT

kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite

# 1. A user SparkApplication that the operator has reconciled to completion.
kubectl -n "${NAMESPACE}" apply -f "${SPARK_APPLICATION_YAML}"
wait_for_application_state "${RETAINED_APPLICATION}" COMPLETED
APPLICATION_IDENTIFIER_BEFORE=$(kubectl -n "${NAMESPACE}" get sparkapplication \
  "${RETAINED_APPLICATION}" -o jsonpath='{.metadata.uid}')
DEFINITION_IDENTIFIERS_BEFORE=$(definition_identifiers)

# 2. Uninstall the release.
helm uninstall spark-operator --namespace kubeflow --wait --timeout 5m

# 3. The definitions and the user object remain with the same identity.
[[ "$(definition_identifiers)" == "${DEFINITION_IDENTIFIERS_BEFORE}" ]]
APPLICATION_IDENTIFIER_AFTER=$(kubectl -n "${NAMESPACE}" get sparkapplication \
  "${RETAINED_APPLICATION}" -o jsonpath='{.metadata.uid}')
[[ "${APPLICATION_IDENTIFIER_AFTER}" == "${APPLICATION_IDENTIFIER_BEFORE}" ]]

# 4. The operator workloads and the aggregated roles are deleted.
for deployment in "${OPERATOR_DEPLOYMENTS[@]}"; do
  [[ -z "$(kubectl -n kubeflow get deployment "${deployment}" --ignore-not-found -o name)" ]]
done
kubectl -n kubeflow wait --for=delete pod -l app.kubernetes.io/name=spark-operator --timeout=180s
for role in "${AGGREGATED_ROLES[@]}"; do
  [[ -z "$(kubectl get clusterrole "${role}" --ignore-not-found -o name)" ]]
done

# 5. Reinstall. The definitions already exist, so Helm does not touch them.
./tests/spark_helm_install.sh
[[ "$(definition_identifiers)" == "${DEFINITION_IDENTIFIERS_BEFORE}" ]]
for role in "${AGGREGATED_ROLES[@]}"; do
  kubectl get clusterrole "${role}"
done

# 6. The operator reconciles again: a new application completes.
sed "s/^  name: ${RETAINED_APPLICATION}\$/  name: ${NEW_APPLICATION}/" "${SPARK_APPLICATION_YAML}" \
  | kubectl -n "${NAMESPACE}" apply -f -
wait_for_application_state "${NEW_APPLICATION}" COMPLETED

# 7. The retained application is observed by the new controller: it still has
# the same identity, and the controller emits an event for a change to it.
[[ "$(kubectl -n "${NAMESPACE}" get sparkapplication "${RETAINED_APPLICATION}" \
  -o jsonpath='{.metadata.uid}')" == "${APPLICATION_IDENTIFIER_BEFORE}" ]]
CONTROLLER_START=$(kubectl -n kubeflow get pod \
  -l app.kubernetes.io/name=spark-operator,app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].status.startTime}')
kubectl -n kubeflow logs deployment/spark-operator-controller --since-time="${CONTROLLER_START}" \
  | grep -F "${RETAINED_APPLICATION}"

echo "Spark Operator Helm lifecycle verified: definitions and SparkApplication ${APPLICATION_IDENTIFIER_BEFORE} retained, operator and aggregated roles deleted and restored, reconciliation resumed."
