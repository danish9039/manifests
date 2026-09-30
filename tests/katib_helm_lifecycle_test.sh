#!/usr/bin/env bash
# Destructive: run after the Experiment test, only in the disposable Helm CI cluster.
set -euo pipefail
export KF_PROFILE=${1:?Supply the profile namespace used by katib_test.sh}
chart=applications/katib/helm
namespace=kubeflow
temporary=$(mktemp -d)

capture_diagnostics() {
    local directory="logs/katib-lifecycle/$1"
    mkdir -p "$directory" || return 0
    kubectl get deployments,pods,events -n "$namespace" --request-timeout=10s -o yaml >"$directory/resources.yaml" 2>&1 || true
    for deployment in katib-controller katib-db-manager katib-mysql katib-ui; do
        kubectl logs "deployment/$deployment" -n "$namespace" --request-timeout=10s --tail=100 >"$directory/$deployment.log" 2>&1 || true
    done
}
cleanup() {
    local status=$?
    if (( status != 0 )); then capture_diagnostics failure; fi
    rm -rf "$temporary"
    exit "$status"
}
trap cleanup EXIT

retained_identities() {
    kubectl get namespace "$namespace" "$KF_PROFILE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}'
    kubectl get -f "$chart/manifests/platform-crds.yaml" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}'
    kubectl get experiments.kubeflow.org,trials.kubeflow.org -n "$KF_PROFILE" -o json | python3 -c '
import json, sys
resources = json.load(sys.stdin)["items"]
experiment = next(item for item in resources if item["kind"] == "Experiment" and item["metadata"]["name"] == "grid")
trials = [item for item in resources if item["kind"] == "Trial" and any(owner["uid"] == experiment["metadata"]["uid"] for owner in item["metadata"].get("ownerReferences", []))]
assert trials, "Run katib_test.sh before the lifecycle test"
for item in sorted([experiment, *trials], key=lambda item: item["metadata"]["name"]):
    print(item["kind"], item["metadata"]["name"], item["metadata"]["uid"])
'
}
controller_template() {
    kubectl get deployment/katib-controller -n "$namespace" -o json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"]["template"], sort_keys=True))'
}
retained_identities >"$temporary/retained-before"
controller_template >"$temporary/controller-before"
revision=$(helm history katib -n "$namespace" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["revision"])')
cp -a "$chart" "$temporary/chart"
# Change only a disposable chart copy; the committed payload stays generated.
python3 - "$temporary/chart/manifests/platform-resources.yaml" <<'PYTHON'
import sys
from pathlib import Path
import yaml

path = Path(sys.argv[1])
resources = list(yaml.safe_load_all(path.read_text()))
controller = next(item for item in resources if item and item["kind"] == "Deployment" and item["metadata"]["name"] == "katib-controller")
controller["spec"]["template"]["metadata"].setdefault("annotations", {})["tests.kubeflow.org/lifecycle"] = "changed"
path.write_text(yaml.safe_dump_all(resources, sort_keys=False))
PYTHON
capture_diagnostics before-upgrade
helm upgrade katib "$temporary/chart" -n "$namespace" --wait --timeout 5m
kubectl rollout status deployment/katib-controller -n "$namespace" --timeout=300s
[[ $(kubectl get deployment/katib-controller -n "$namespace" -o jsonpath='{.spec.template.metadata.annotations.tests\.kubeflow\.org/lifecycle}') == changed ]]
helm rollback katib "$revision" -n "$namespace" --wait --timeout 5m
kubectl rollout status deployment/katib-controller -n "$namespace" --timeout=300s
controller_template >"$temporary/controller-after"
diff -u "$temporary/controller-before" "$temporary/controller-after"

capture_diagnostics before-uninstall
helm uninstall katib -n "$namespace" --wait --timeout 5m
retained_identities >"$temporary/retained-after"
diff -u "$temporary/retained-before" "$temporary/retained-after"
# Match the current chart contract: objects survive, database storage does not.
for resource in pvc/katib-mysql secret/katib-mysql-secrets; do
    [[ -z $(kubectl get "$resource" -n "$namespace" --ignore-not-found -o name) ]]
done
./tests/katib_helm_install.sh
for deployment in katib-controller katib-db-manager katib-mysql katib-ui; do
    kubectl rollout status "deployment/$deployment" -n "$namespace" --timeout=300s
done
kubectl get pvc/katib-mysql secret/katib-mysql-secrets -n "$namespace" >/dev/null
retained_identities >"$temporary/retained-after"
diff -u "$temporary/retained-before" "$temporary/retained-after"
echo "Katib upgrade, rollback, retention and reinstall readiness passed; no second Experiment was run."
