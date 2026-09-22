#!/usr/bin/env bash
# Called by the Helm integration workflow while the UI test owns a real,
# Ready InferenceService. This script operates only the Models UI release.
set -euo pipefail
SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPOSITORY_ROOT=$(dirname "$SCRIPT_DIRECTORY")
CHART_DIRECTORY="${REPOSITORY_ROOT}/applications/kserve/kserve-ui/helm"
RELEASE_NAME=kserve-models-web-application
RELEASE_NAMESPACE=kserve
TEST_NAMESPACE=${1:?Pass the namespace of an existing Ready InferenceService}
INFERENCE_SERVICE_NAME=${2:?Pass the existing Ready InferenceService name}
TEMPORARY_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT

# Record object UIDs rather than accepting deletion followed by recreation.
kubectl get namespace kserve -o json > "${TEMPORARY_DIRECTORY}/namespace-before.json"
kubectl get deployments --namespace kserve -o json > "${TEMPORARY_DIRECTORY}/controllers-before.json"
kubectl get inferenceservice "$INFERENCE_SERVICE_NAME" --namespace "$TEST_NAMESPACE" \
  -o json > "${TEMPORARY_DIRECTORY}/inference-service-before.json"

assert_other_owners_survive() {
  kubectl get namespace kserve -o json > "${TEMPORARY_DIRECTORY}/namespace-after.json"
  kubectl get deployments --namespace kserve -o json > "${TEMPORARY_DIRECTORY}/controllers-after.json"
  kubectl get inferenceservice "$INFERENCE_SERVICE_NAME" --namespace "$TEST_NAMESPACE" \
    -o json > "${TEMPORARY_DIRECTORY}/inference-service-after.json"
  python3 - "$TEMPORARY_DIRECTORY" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for resource in ("namespace", "inference-service"):
    before = json.loads((root / f"{resource}-before.json").read_text())
    after = json.loads((root / f"{resource}-after.json").read_text())
    assert before["metadata"]["uid"] == after["metadata"]["uid"], resource
controllers = {}
for stage in ("before", "after"):
    documents = json.loads((root / f"controllers-{stage}.json").read_text())["items"]
    controllers[stage] = {
        document["metadata"]["name"]: document["metadata"]["uid"]
        for document in documents
        if document["metadata"]["name"] != "kserve-models-web-application"
    }
assert "kserve-controller-manager" in controllers["before"]
for name, uid in controllers["before"].items():
    assert controllers["after"].get(name) == uid, name
PY
  kubectl wait --for=condition=Ready "inferenceservice/${INFERENCE_SERVICE_NAME}" \
    --namespace "$TEST_NAMESPACE" --timeout=120s
}

BASELINE_REVISION=$(helm status "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" --output json |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')

# An unchanged upgrade exercises normal Helm ownership without force flags.
helm upgrade "$RELEASE_NAME" "$CHART_DIRECTORY" --namespace "$RELEASE_NAMESPACE" \
  --wait --timeout 5m
assert_other_owners_survive

# A disposable chart represents a compatible next chart revision. Change the
# Deployment replica count without adding an unsupported public values knob.
cp -R "$CHART_DIRECTORY" "${TEMPORARY_DIRECTORY}/chart"
python3 - "${TEMPORARY_DIRECTORY}/chart/manifests/platform-resources.yaml" <<'PY'
import sys
from pathlib import Path
import yaml

path = Path(sys.argv[1])
resources = [resource for resource in yaml.safe_load_all(path.read_text()) if resource]
deployments = [resource for resource in resources if resource["kind"] == "Deployment"]
assert len(deployments) == 1
deployments[0]["spec"]["replicas"] = 2
path.write_text(yaml.safe_dump_all(resources, sort_keys=False))
PY
helm upgrade "$RELEASE_NAME" "${TEMPORARY_DIRECTORY}/chart" \
  --namespace "$RELEASE_NAMESPACE" --wait --timeout 5m
[[ "$(kubectl get deployment "$RELEASE_NAME" --namespace kserve -o jsonpath='{.spec.replicas}')" == 2 ]]
assert_other_owners_survive

helm rollback "$RELEASE_NAME" "$BASELINE_REVISION" --namespace "$RELEASE_NAMESPACE" \
  --wait --timeout 5m
[[ "$(kubectl get deployment "$RELEASE_NAME" --namespace kserve -o jsonpath='{.spec.replicas}')" == 1 ]]
assert_other_owners_survive

helm uninstall "$RELEASE_NAME" --namespace "$RELEASE_NAMESPACE" --wait --timeout 5m
[[ -z "$(kubectl get deployment "$RELEASE_NAME" --namespace kserve --ignore-not-found -o name)" ]]
assert_other_owners_survive
"${SCRIPT_DIRECTORY}/kserve_ui_helm_install.sh"
assert_other_owners_survive
# The calling API test now repeats the authenticated object lookup and tests
# rejection of an unauthorized token against the recovered UI.
