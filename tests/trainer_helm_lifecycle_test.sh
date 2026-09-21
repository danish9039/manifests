#!/usr/bin/env bash
# Destructive release-boundary test for an explicitly selected disposable cluster.
# Requires tests/trainer_helm_install.sh and platform prerequisites beforehand.
# This does not prove schema-version compatibility or runtime image/snapshot skew.
set -euxo pipefail

: "${KUBECONFIG:?Provide the disposable cluster kubeconfig explicitly}"
if [[ "${TRAINER_HELM_LIFECYCLE_DISPOSABLE:-}" != true ]]; then
  echo 'Set TRAINER_HELM_LIFECYCLE_DISPOSABLE=true only for a disposable cluster.' >&2
  exit 1
fi
REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPOSITORY_ROOT"
TEST_NAMESPACE=${1:-kubeflow-user-example-com}
TEST_JOB=trainer-helm-retained-fixture
TEST_RUNTIME=trainer-helm-administrator-runtime
TEST_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
export TEST_NAMESPACE TEST_RUNTIME TEST_DIRECTORY

for release in trainer-apis trainer trainer-runtimes; do
  helm status "$release" --namespace kubeflow-system
done
kubectl get namespace "$TEST_NAMESPACE"
NAMESPACE_UID=$(kubectl get namespace kubeflow-system -o jsonpath='{.metadata.uid}')

uid() {
  kubectl get "$1" ${2:+--namespace "$2"} -o jsonpath='{.metadata.uid}'
}

assert_uid() {
  local actual
  actual=$(uid "$1" "${3:-}")
  [[ -n "$actual" && "$actual" == "$2" ]]
}

# This runtime is administrator-owned and not selected by a Helm deletion hook.
kubectl get clustertrainingruntime torch-distributed -o json > "$TEST_DIRECTORY/runtime.json"
python3 - <<'PY' | kubectl create -f -
import json, os
from pathlib import Path
runtime = json.loads((Path(os.environ["TEST_DIRECTORY"]) / "runtime.json").read_text())
runtime["metadata"] = {"name": os.environ["TEST_RUNTIME"]}
runtime.pop("status", None)
print(json.dumps(runtime))
PY
ADMINISTRATOR_RUNTIME_UID=$(uid "clustertrainingruntime/${TEST_RUNTIME}")
CATALOG_RUNTIME_UID=$(uid clustertrainingruntime/torch-distributed)
kubectl create --namespace "$TEST_NAMESPACE" -f - <<EOF
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: ${TEST_JOB}
spec:
  suspend: true
  runtimeRef:
    name: torch-distributed
  trainer:
    numNodes: 1
    command: ["python", "-c", "print('trainer lifecycle fixture')"]
EOF
JOB_UID=$(uid "trainjob/${TEST_JOB}" "$TEST_NAMESPACE")
kubectl wait --namespace "$TEST_NAMESPACE" --for=create \
  "configmap/${TEST_JOB}-runtime-snapshot" --timeout=180s
SNAPSHOT_UID=$(uid "configmap/${TEST_JOB}-runtime-snapshot" "$TEST_NAMESPACE")

for definition in clustertrainingruntimes.trainer.kubeflow.org \
  trainingruntimes.trainer.kubeflow.org trainjobs.trainer.kubeflow.org jobsets.jobset.x-k8s.io; do
  uid "crd/${definition}" > "$TEST_DIRECTORY/${definition}.uid"
done

# Use a changed Pod template, not a no-op upgrade, to exercise rollout/rollback.
cp -R applications/trainer/helm "$TEST_DIRECTORY/controller"
python3 - <<'PY'
import os
from pathlib import Path
import yaml
path = Path(os.environ["TEST_DIRECTORY"]) / "controller/manifests/platform-resources.yaml"
resources = list(yaml.safe_load_all(path.read_text()))
for resource in resources:
    if resource["kind"] == "Deployment":
        resource["spec"]["template"]["metadata"].setdefault("annotations", {})[
            "trainer.kubeflow.org/lifecycle-test"
        ] = "changed"
path.write_text(yaml.safe_dump_all(resources, sort_keys=False))
PY
CONTROLLER_REVISION=$(helm history trainer --namespace kubeflow-system --output json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["revision"])')
helm upgrade trainer "$TEST_DIRECTORY/controller" --namespace kubeflow-system --wait --timeout 10m
helm rollback trainer "$CONTROLLER_REVISION" --namespace kubeflow-system --wait --timeout 10m
assert_uid "trainjob/${TEST_JOB}" "$JOB_UID" "$TEST_NAMESPACE"
assert_uid "configmap/${TEST_JOB}-runtime-snapshot" "$SNAPSHOT_UID" "$TEST_NAMESPACE"

helm uninstall trainer --namespace kubeflow-system --wait --timeout 5m
for webhook in mutatingwebhookconfiguration/defaulter.trainer.kubeflow.org \
  mutatingwebhookconfiguration/jobset-mutating-webhook-configuration \
  validatingwebhookconfiguration/validator.trainer.kubeflow.org \
  validatingwebhookconfiguration/jobset-validating-webhook-configuration; do
  [[ -z "$(kubectl get "$webhook" --ignore-not-found -o name)" ]]
done
assert_uid "namespace/kubeflow-system" "$NAMESPACE_UID"
assert_uid "trainjob/${TEST_JOB}" "$JOB_UID" "$TEST_NAMESPACE"
assert_uid "clustertrainingruntime/${TEST_RUNTIME}" "$ADMINISTRATOR_RUNTIME_UID"
assert_uid clustertrainingruntime/torch-distributed "$CATALOG_RUNTIME_UID"
helm install trainer applications/trainer/helm --namespace kubeflow-system --wait --timeout 10m
for webhook in mutatingwebhookconfiguration/defaulter.trainer.kubeflow.org \
  mutatingwebhookconfiguration/jobset-mutating-webhook-configuration \
  validatingwebhookconfiguration/validator.trainer.kubeflow.org \
  validatingwebhookconfiguration/jobset-validating-webhook-configuration; do
  kubectl wait "$webhook" --timeout=120s \
    --for='jsonpath={.webhooks[0].clientConfig.caBundle}'
done

# A fresh successful SDK job proves admission and reconciliation after recovery;
# retained status alone would not establish that the controller works again.
./tests/trainer_test.sh "$TEST_NAMESPACE"

# Deliberately remove the catalog with a referenced suspended fixture to expose
# the documented live-runtime admission dependency. Real administration must
# migrate such consumers first. Retention of the snapshot is checked separately.
helm uninstall trainer-runtimes --namespace kubeflow-system --wait --timeout 5m
[[ -z "$(kubectl get clustertrainingruntime torch-distributed --ignore-not-found -o name)" ]]
assert_uid "clustertrainingruntime/${TEST_RUNTIME}" "$ADMINISTRATOR_RUNTIME_UID"
assert_uid "trainjob/${TEST_JOB}" "$JOB_UID" "$TEST_NAMESPACE"
assert_uid "configmap/${TEST_JOB}-runtime-snapshot" "$SNAPSHOT_UID" "$TEST_NAMESPACE"
if kubectl patch "trainjob/${TEST_JOB}" --namespace "$TEST_NAMESPACE" \
  --type merge -p '{"spec":{"suspend":false}}' > "$TEST_DIRECTORY/retirement.txt" 2>&1; then
  echo 'Unexpectedly admitted an update after deleting its referenced runtime.' >&2
  exit 1
fi
# Reject unrelated network/authorization failures as evidence for admission.
grep -Ei 'admission webhook.*denied|denied the request' "$TEST_DIRECTORY/retirement.txt"
grep -F 'torch-distributed' "$TEST_DIRECTORY/retirement.txt"
helm install trainer-runtimes applications/trainer/helm-runtimes \
  --namespace kubeflow-system --wait --timeout 5m

helm uninstall trainer-apis --namespace kubeflow-system --wait --timeout 5m
for definition in clustertrainingruntimes.trainer.kubeflow.org \
  trainingruntimes.trainer.kubeflow.org trainjobs.trainer.kubeflow.org jobsets.jobset.x-k8s.io; do
  assert_uid "crd/${definition}" "$(cat "$TEST_DIRECTORY/${definition}.uid")"
done
assert_uid "trainjob/${TEST_JOB}" "$JOB_UID" "$TEST_NAMESPACE"
assert_uid "configmap/${TEST_JOB}-runtime-snapshot" "$SNAPSHOT_UID" "$TEST_NAMESPACE"
helm install trainer-apis applications/trainer/helm-crds \
  --namespace kubeflow-system --wait --timeout 5m
for definition in clustertrainingruntimes.trainer.kubeflow.org \
  trainingruntimes.trainer.kubeflow.org trainjobs.trainer.kubeflow.org jobsets.jobset.x-k8s.io; do
  assert_uid "crd/${definition}" "$(cat "$TEST_DIRECTORY/${definition}.uid")"
done
assert_uid "trainjob/${TEST_JOB}" "$JOB_UID" "$TEST_NAMESPACE"
assert_uid "namespace/kubeflow-system" "$NAMESPACE_UID"

kubectl delete "trainjob/${TEST_JOB}" --namespace "$TEST_NAMESPACE" --wait --timeout=180s
kubectl wait "configmap/${TEST_JOB}-runtime-snapshot" --namespace "$TEST_NAMESPACE" \
  --for=delete --timeout=180s
kubectl delete "clustertrainingruntime/${TEST_RUNTIME}"
echo 'PASS: Trainer release boundaries and recovery; schema skew and runtime image/snapshot update gates require separate tests.'
