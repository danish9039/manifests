#!/usr/bin/env bash
# Lifecycle evidence for the Kubeflow Workspaces Helm chart
# (applications/workspaces/helm). It is not part of a workflow; it needs a
# cluster on which tests/workspaces_helm_install.sh has already succeeded and on
# which the profile namespace exists.
#
# 1. Fixture A: a Workspace is deleted explicitly. Its dependent objects must
#    disappear. What happens to its PersistentVolumeClaim is recorded as
#    observed, not assumed.
# 2. Fixture B: a Workspace with a PersistentVolumeClaim in the profile
#    namespace, plus a sentinel ConfigMap inside kubeflow-workspaces that the
#    release does not own. The release is uninstalled; the namespace must
#    terminate together with the sentinel, while the definitions, the
#    WorkspaceKind, fixture B and its claim must remain with unchanged UIDs.
# 3. The release is installed again after the namespace has terminated. The
#    validating webhook must serve again (an invalid Workspace is rejected) and
#    fixture B must be reconciled again.
# 4. A kubeflow-workspaces namespace that the release does not own must make the
#    installation fail. The real error text is recorded.
#
# The script is destructive: it uninstalls the release and deletes the
# kubeflow-workspaces namespace. It ends with the release installed again.
set -euxo pipefail

KF_PROFILE="${1:-kubeflow-user-example-com}"
EVIDENCE_DIRECTORY="${EVIDENCE_DIRECTORY:-$(mktemp -d)}"
RELEASE_NAME="kubeflow-workspaces"
RELEASE_NAMESPACE="kubeflow"
WORKLOAD_NAMESPACE="kubeflow-workspaces"
WORKSPACE_KIND="jupyterlab"
WORKSPACE_DEFINITIONS=(workspacekinds.kubeflow.org workspaces.kubeflow.org)
WORKSPACE_LABEL="notebooks.kubeflow.org/workspace-name"
TIMEOUT_SECONDS=600

mkdir -p "${EVIDENCE_DIRECTORY}"
echo "Evidence is written to ${EVIDENCE_DIRECTORY}"

object_uid() {
  kubectl get "$@" -o jsonpath='{.metadata.uid}'
}

# Names of the objects of one kind, in the profile namespace, that an owner
# reference ties to the given Workspace UID.
owned_objects() {
  local kind="$1"
  local owner_uid="$2"
  kubectl get "${kind}" -n "${KF_PROFILE}" -o json |
    jq -r --arg uid "${owner_uid}" \
      '.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid)) | .metadata.name'
}

wait_until_no_owned_objects() {
  local kind="$1"
  local owner_uid="$2"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [[ -n "$(owned_objects "${kind}" "${owner_uid}")" ]]; do
    if ((SECONDS >= deadline)); then
      echo "Error, ${kind} objects owned by ${owner_uid} still exist."
      owned_objects "${kind}" "${owner_uid}"
      return 1
    fi
    sleep 5
  done
}

create_workspace_with_claim() {
  local workspace_name="$1"
  local claim_name="$2"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${claim_name}
  namespace: ${KF_PROFILE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: kubeflow.org/v1beta1
kind: Workspace
metadata:
  name: ${workspace_name}
  namespace: ${KF_PROFILE}
spec:
  paused: false
  kind: "${WORKSPACE_KIND}"
  podTemplate:
    volumes:
      home: "${claim_name}"
    options:
      imageConfig: "jupyter-scipy:v1.10.0"
      podConfig: "tiny_cpu"
EOF
  kubectl wait --for=jsonpath='{.status.state}'=Running \
    "workspace/${workspace_name}" -n "${KF_PROFILE}" \
    --timeout="${TIMEOUT_SECONDS}s"
}

wait_for_validating_webhook() {
  kubectl wait --for=condition=Ready certificate/workspaces-serving-cert \
    -n "${WORKLOAD_NAMESPACE}" --timeout=300s

  local deadline=$((SECONDS + 300))
  until [[ -n "$(kubectl get validatingwebhookconfiguration \
    workspaces-validating-webhook-configuration \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}')" ]]; do
    if ((SECONDS >= deadline)); then
      echo "Error, cert-manager did not inject the certificate authority bundle."
      return 1
    fi
    sleep 5
  done

  until [[ -n "$(kubectl get endpoints workspaces-webhook-service \
    -n "${WORKLOAD_NAMESPACE}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}')" ]]; do
    if ((SECONDS >= deadline)); then
      echo "Error, the webhook service has no ready endpoint."
      return 1
    fi
    sleep 5
  done
}

# A Workspace that names a WorkspaceKind which does not exist passes the schema
# of the definition, so only the validating webhook can reject it.
assert_invalid_workspace_is_rejected() {
  local output_file="${EVIDENCE_DIRECTORY}/invalid-workspace-rejection.txt"
  local deadline=$((SECONDS + 300))
  while true; do
    if kubectl apply -f - >"${output_file}" 2>&1 <<EOF
apiVersion: kubeflow.org/v1beta1
kind: Workspace
metadata:
  name: lifecycle-invalid
  namespace: ${KF_PROFILE}
spec:
  paused: true
  kind: "lifecycle-kind-that-does-not-exist"
  podTemplate:
    volumes:
      home: "lifecycle-invalid-home"
    options:
      imageConfig: "jupyter-scipy:v1.10.0"
      podConfig: "tiny_cpu"
EOF
    then
      cat "${output_file}"
      kubectl delete workspace lifecycle-invalid -n "${KF_PROFILE}" --wait=false
      echo "Error, the invalid Workspace was admitted."
      return 1
    fi
    cat "${output_file}"
    if grep -q "denied the request" "${output_file}"; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      echo "Error, the validating webhook did not reject the invalid Workspace."
      return 1
    fi
    sleep 5
  done
}

record_inventory() {
  local label="$1"
  {
    kubectl get namespace "${WORKLOAD_NAMESPACE}" --ignore-not-found -o wide
    kubectl get customresourcedefinition "${WORKSPACE_DEFINITIONS[@]}" \
      -o custom-columns=NAME:.metadata.name,UID:.metadata.uid || true
    kubectl get workspacekind \
      -o custom-columns=NAME:.metadata.name,UID:.metadata.uid || true
    kubectl get workspace,persistentvolumeclaim -n "${KF_PROFILE}" \
      -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid || true
    helm list --namespace "${RELEASE_NAMESPACE}" --all
  } >"${EVIDENCE_DIRECTORY}/inventory-${label}.txt" 2>&1
  cat "${EVIDENCE_DIRECTORY}/inventory-${label}.txt"
}

helm status "${RELEASE_NAME}" --namespace "${RELEASE_NAMESPACE}"
kubectl get namespace "${KF_PROFILE}"
kubectl apply -f tests/workspacekind.test.yaml
WORKSPACE_KIND_UID="$(object_uid workspacekind "${WORKSPACE_KIND}")"

echo "Fixture A: explicit deletion of a Workspace ..."
create_workspace_with_claim lifecycle-delete lifecycle-delete-home
FIXTURE_A_UID="$(object_uid workspace lifecycle-delete -n "${KF_PROFILE}")"
FIXTURE_A_CLAIM_UID="$(object_uid persistentvolumeclaim lifecycle-delete-home -n "${KF_PROFILE}")"
{
  for kind in statefulset service virtualservice; do
    echo "${kind}: $(owned_objects "${kind}" "${FIXTURE_A_UID}" | tr '\n' ' ')"
  done
  echo "pod: $(kubectl get pods -n "${KF_PROFILE}" \
    -l "${WORKSPACE_LABEL}=lifecycle-delete" -o name | tr '\n' ' ')"
} | tee "${EVIDENCE_DIRECTORY}/fixture-a-dependent-objects.txt"
if [[ -z "$(owned_objects statefulset "${FIXTURE_A_UID}")" ]]; then
  echo "Error, fixture A owns no StatefulSet, so the deletion check would prove nothing."
  exit 1
fi

kubectl delete workspace lifecycle-delete -n "${KF_PROFILE}" --timeout="${TIMEOUT_SECONDS}s"
for kind in statefulset service virtualservice; do
  wait_until_no_owned_objects "${kind}" "${FIXTURE_A_UID}"
done
kubectl wait --for=delete pods -n "${KF_PROFILE}" \
  -l "${WORKSPACE_LABEL}=lifecycle-delete" --timeout="${TIMEOUT_SECONDS}s"

# The claim is user data. Whether it remains is recorded as observed.
FIXTURE_A_CLAIM_UID_AFTER="$(kubectl get persistentvolumeclaim lifecycle-delete-home \
  -n "${KF_PROFILE}" --ignore-not-found -o jsonpath='{.metadata.uid}')"
{
  echo "claim UID before Workspace deletion: ${FIXTURE_A_CLAIM_UID}"
  echo "claim UID after Workspace deletion: ${FIXTURE_A_CLAIM_UID_AFTER:-<claim no longer exists>}"
} | tee "${EVIDENCE_DIRECTORY}/fixture-a-claim.txt"
kubectl delete persistentvolumeclaim lifecycle-delete-home -n "${KF_PROFILE}" \
  --ignore-not-found --timeout="${TIMEOUT_SECONDS}s"

echo "Fixture B: a retained Workspace and a sentinel that the release does not own ..."
create_workspace_with_claim lifecycle-retained lifecycle-retained-home
FIXTURE_B_UID="$(object_uid workspace lifecycle-retained -n "${KF_PROFILE}")"
FIXTURE_B_CLAIM_UID="$(object_uid persistentvolumeclaim lifecycle-retained-home -n "${KF_PROFILE}")"
kubectl create configmap lifecycle-sentinel -n "${WORKLOAD_NAMESPACE}" \
  --from-literal=owner=not-the-helm-release
declare -A DEFINITION_UIDS
for definition in "${WORKSPACE_DEFINITIONS[@]}"; do
  DEFINITION_UIDS["${definition}"]="$(object_uid customresourcedefinition "${definition}")"
done
record_inventory before-uninstall

helm uninstall "${RELEASE_NAME}" --namespace "${RELEASE_NAMESPACE}" --wait --timeout 5m \
  2>&1 | tee "${EVIDENCE_DIRECTORY}/helm-uninstall.txt"
kubectl wait --for=delete "namespace/${WORKLOAD_NAMESPACE}" --timeout="${TIMEOUT_SECONDS}s"
record_inventory after-uninstall

if kubectl get namespace "${WORKLOAD_NAMESPACE}"; then
  echo "Error, the ${WORKLOAD_NAMESPACE} namespace still exists after the uninstall."
  exit 1
fi
# The sentinel and the control plane lived inside the namespace, so both are
# gone with it. The cluster-scoped objects of the release are checked by name.
for cluster_object in \
  clusterrole/workspaces-manager-role \
  clusterrolebinding/workspaces-manager-rolebinding \
  validatingwebhookconfiguration/workspaces-validating-webhook-configuration; do
  if [[ -n "$(kubectl get "${cluster_object}" --ignore-not-found -o name)" ]]; then
    echo "Error, ${cluster_object} still exists after the uninstall."
    exit 1
  fi
done
for definition in "${WORKSPACE_DEFINITIONS[@]}"; do
  test "$(object_uid customresourcedefinition "${definition}")" = "${DEFINITION_UIDS[${definition}]}"
done
test "$(object_uid workspacekind "${WORKSPACE_KIND}")" = "${WORKSPACE_KIND_UID}"
test "$(object_uid workspace lifecycle-retained -n "${KF_PROFILE}")" = "${FIXTURE_B_UID}"
test "$(object_uid persistentvolumeclaim lifecycle-retained-home -n "${KF_PROFILE}")" = "${FIXTURE_B_CLAIM_UID}"

echo "Pre-existing namespace that the release does not own ..."
kubectl create namespace "${WORKLOAD_NAMESPACE}"
if helm install "${RELEASE_NAME}" applications/workspaces/helm \
  --namespace "${RELEASE_NAMESPACE}" \
  --values applications/workspaces/helm/ci/values-istio.yaml \
  >"${EVIDENCE_DIRECTORY}/foreign-namespace-refusal.txt" 2>&1; then
  cat "${EVIDENCE_DIRECTORY}/foreign-namespace-refusal.txt"
  echo "Error, the installation adopted a namespace that the release does not own."
  exit 1
fi
cat "${EVIDENCE_DIRECTORY}/foreign-namespace-refusal.txt"
# A refused installation can leave a failed release record behind.
helm list --namespace "${RELEASE_NAMESPACE}" --all --filter "^${RELEASE_NAME}\$" \
  | tee "${EVIDENCE_DIRECTORY}/foreign-namespace-release-record.txt"
if helm status "${RELEASE_NAME}" --namespace "${RELEASE_NAMESPACE}" >/dev/null 2>&1; then
  helm uninstall "${RELEASE_NAME}" --namespace "${RELEASE_NAMESPACE}" --wait --timeout 5m
fi
kubectl delete namespace "${WORKLOAD_NAMESPACE}" --ignore-not-found --timeout="${TIMEOUT_SECONDS}s"
kubectl wait --for=delete "namespace/${WORKLOAD_NAMESPACE}" --timeout="${TIMEOUT_SECONDS}s"
for definition in "${WORKSPACE_DEFINITIONS[@]}"; do
  test "$(object_uid customresourcedefinition "${definition}")" = "${DEFINITION_UIDS[${definition}]}"
done

echo "Reinstallation after the namespace has terminated ..."
./tests/workspaces_helm_install.sh
wait_for_validating_webhook
assert_invalid_workspace_is_rejected
for definition in "${WORKSPACE_DEFINITIONS[@]}"; do
  test "$(object_uid customresourcedefinition "${definition}")" = "${DEFINITION_UIDS[${definition}]}"
done
test "$(object_uid workspace lifecycle-retained -n "${KF_PROFILE}")" = "${FIXTURE_B_UID}"
test "$(object_uid persistentvolumeclaim lifecycle-retained-home -n "${KF_PROFILE}")" = "${FIXTURE_B_CLAIM_UID}"

# Reconciliation is proven by a change that only the controller can act on: the
# retained Workspace is paused and resumed, and its state has to follow.
kubectl patch workspace lifecycle-retained -n "${KF_PROFILE}" --type=merge \
  --patch '{"spec":{"paused":true}}'
kubectl wait --for=jsonpath='{.status.state}'=Paused \
  workspace/lifecycle-retained -n "${KF_PROFILE}" --timeout="${TIMEOUT_SECONDS}s"
kubectl patch workspace lifecycle-retained -n "${KF_PROFILE}" --type=merge \
  --patch '{"spec":{"paused":false}}'
kubectl wait --for=jsonpath='{.status.state}'=Running \
  workspace/lifecycle-retained -n "${KF_PROFILE}" --timeout="${TIMEOUT_SECONDS}s"
record_inventory after-reinstall

kubectl delete workspace lifecycle-retained -n "${KF_PROFILE}" --timeout="${TIMEOUT_SECONDS}s"
kubectl delete persistentvolumeclaim lifecycle-retained-home -n "${KF_PROFILE}" \
  --ignore-not-found --timeout="${TIMEOUT_SECONDS}s"
echo "Workspaces Helm lifecycle test completed. Evidence: ${EVIDENCE_DIRECTORY}"
