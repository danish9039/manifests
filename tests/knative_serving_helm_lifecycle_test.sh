#!/usr/bin/env bash
# Destructive release lifecycle gate: run only on the disposable integration cluster.
set -euo pipefail
namespace=${1:?Usage: knative_serving_helm_lifecycle_test.sh PROFILE_NAMESPACE}
chart=common/knative/knative-serving/helm
fixture=knative-helm-routing
temporary=$(mktemp -d)
EVIDENCE_DIRECTORY=${EVIDENCE_DIRECTORY:-logs/knative-serving-lifecycle}
mkdir -p "$EVIDENCE_DIRECTORY"
capture_diagnostics() {
    timeout --kill-after=5s 60s bash tests/helm_lifecycle_diagnostics.sh \
        "$EVIDENCE_DIRECTORY/$1" kubeflow knative-serving knative-serving "$namespace" || true
    timeout --kill-after=2s 10s kubectl --request-timeout=5s get \
        services.serving.knative.dev,revisions.serving.knative.dev,routes.serving.knative.dev,authorizationpolicies \
        -n "$namespace" -o yaml >"$EVIDENCE_DIRECTORY/$1/serving-resources.yaml" 2>&1 || true
}
cleanup() {
    local status=$?
    set +e
    if [[ "$status" -ne 0 ]]; then
        capture_diagnostics failure
    else
        kubectl --request-timeout=10s delete services.serving.knative.dev "$fixture" -n "$namespace" --ignore-not-found --timeout=30s || status=$?
        kubectl --request-timeout=10s delete authorizationpolicy "$fixture" -n "$namespace" --ignore-not-found --timeout=30s || status=$?
        if [[ "$status" -ne 0 ]]; then capture_diagnostics failure; fi
    fi
    rm -rf "$temporary"
    exit "$status"
}
trap cleanup EXIT
./tests/knative_serving_helm_admission_test.sh
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
uid=$(kubectl get services.serving.knative.dev "$fixture" -n "$namespace" -o jsonpath='{.metadata.uid}')
namespace_uid=$(kubectl get namespace knative-serving -o jsonpath='{.metadata.uid}')
capture_diagnostics before-upgrade
helm upgrade knative-serving "$chart" -n kubeflow --wait --timeout 10m
./tests/knative_serving_helm_admission_test.sh
revision=$(helm history knative-serving -n kubeflow -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["revision"])')
cp -a "$chart" "$temporary/chart"
# A disposable candidate changes the controller Pod template, proving a real
# workload rollout instead of only incrementing the stored release revision.
python3 - "$temporary/chart/manifests/platform-resources.yaml" <<'PYTHON'
import sys
from pathlib import Path
import yaml
path = Path(sys.argv[1])
resources = list(yaml.safe_load_all(path.read_text()))
controllers = [r for r in resources if r and r["kind"] == "Deployment" and r["metadata"]["name"] == "controller"]
assert len(controllers) == 1, "Expected one controller Deployment"
controllers[0]["spec"]["template"]["metadata"].setdefault("annotations", {})["tests.kubeflow.org/lifecycle"] = "changed"
path.write_text(yaml.safe_dump_all(resources, sort_keys=False))
PYTHON
cp "$temporary/chart/manifests/platform-resources.yaml" "$EVIDENCE_DIRECTORY/candidate-resources.yaml"
capture_diagnostics before-changed-upgrade
helm upgrade knative-serving "$temporary/chart" -n kubeflow --wait --timeout 10m
kubectl rollout status deployment/controller -n knative-serving --timeout=120s
./tests/knative_serving_helm_admission_test.sh
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
capture_diagnostics before-rollback
helm rollback knative-serving "$revision" -n kubeflow --wait --timeout 10m
./tests/knative_serving_helm_admission_test.sh
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
capture_diagnostics before-uninstall
helm uninstall knative-serving -n kubeflow --wait --timeout 10m
[[ $(kubectl get services.serving.knative.dev "$fixture" -n "$namespace" -o jsonpath='{.metadata.uid}') == "$uid" ]]
[[ $(kubectl get namespace knative-serving -o jsonpath='{.metadata.uid}') == "$namespace_uid" ]]
kubectl get -f "$chart/manifests/platform-crds.yaml" >/dev/null
./tests/knative_serving_helm_install.sh
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
[[ $(kubectl get services.serving.knative.dev "$fixture" -n "$namespace" -o jsonpath='{.metadata.uid}') == "$uid" ]]
capture_diagnostics recovered
echo "Serving upgrade, changed rollout, complete-revision rollback, retained objects and route recovery passed."
