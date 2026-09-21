#!/usr/bin/env bash
# Destructive release lifecycle gate: run only on the disposable integration cluster.
set -euo pipefail
namespace=${1:?Usage: knative_serving_helm_lifecycle_test.sh PROFILE_NAMESPACE}
chart=common/knative/knative-serving/helm
fixture=knative-helm-routing
temporary=$(mktemp -d)
cleanup() {
    rm -rf "$temporary"
    kubectl delete services.serving.knative.dev "$fixture" -n "$namespace" --ignore-not-found
    kubectl delete authorizationpolicy "$fixture" -n "$namespace" --ignore-not-found
}
trap cleanup EXIT
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
uid=$(kubectl get services.serving.knative.dev "$fixture" -n "$namespace" -o jsonpath='{.metadata.uid}')
namespace_uid=$(kubectl get namespace knative-serving -o jsonpath='{.metadata.uid}')
helm upgrade knative-serving "$chart" -n kubeflow --wait --timeout 10m
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
helm upgrade knative-serving "$temporary/chart" -n kubeflow --wait --timeout 10m
kubectl rollout status deployment/controller -n knative-serving --timeout=120s
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
helm rollback knative-serving "$revision" -n kubeflow --wait --timeout 10m
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
helm uninstall knative-serving -n kubeflow --wait --timeout 10m
[[ $(kubectl get services.serving.knative.dev "$fixture" -n "$namespace" -o jsonpath='{.metadata.uid}') == "$uid" ]]
[[ $(kubectl get namespace knative-serving -o jsonpath='{.metadata.uid}') == "$namespace_uid" ]]
kubectl get -f "$chart/manifests/platform-crds.yaml" >/dev/null
./tests/knative_serving_helm_install.sh
KNATIVE_HELM_KEEP_FIXTURE=true ./tests/knative_serving_helm_smoke_test.sh "$namespace"
[[ $(kubectl get services.serving.knative.dev "$fixture" -n "$namespace" -o jsonpath='{.metadata.uid}') == "$uid" ]]
echo "Serving upgrade, changed rollout, complete-revision rollback, retained objects and route recovery passed."
