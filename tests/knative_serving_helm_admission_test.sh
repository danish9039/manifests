#!/usr/bin/env bash
# Readiness and server-side dry runs only; no probe resource is persisted.
set -euo pipefail

for kind in mutatingwebhookconfiguration validatingwebhookconfiguration; do
    name=webhook.serving.knative.dev
    path=/defaulting
    if [[ "$kind" == validatingwebhookconfiguration ]]; then
        name=validation.webhook.serving.knative.dev
        path=/resource-validation
    fi
    selector=".webhooks[?(@.name==\"$name\")]"
    for field in 'rules[0].operations[0]' clientConfig.caBundle; do
        kubectl wait "$kind/$name" --for="jsonpath={$selector.$field}" --timeout=120s
    done
    kubectl wait "$kind/$name" --for="jsonpath={$selector.clientConfig.service.path}=$path" --timeout=120s
    kubectl wait "$kind/$name" --for="jsonpath={$selector.clientConfig.service.name}=webhook" --timeout=120s
    kubectl wait "$kind/$name" --for="jsonpath={$selector.clientConfig.service.namespace}=knative-serving" --timeout=120s
    kubectl wait "$kind/$name" --for="jsonpath={$selector.failurePolicy}=Fail" --timeout=120s
done

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
cat >"$temporary/service.json" <<'JSON'
{
  "apiVersion": "serving.knative.dev/v1",
  "kind": "Service",
  "metadata": {"generateName": "helm-admission-probe-", "namespace": "knative-serving"},
  "spec": {"template": {"spec": {"containers": [{"image": "hashicorp/http-echo:1.0.0"}]}}}
}
JSON
kubectl create --dry-run=server -f "$temporary/service.json" -o json >"$temporary/defaulted.json"
python3 - "$temporary/defaulted.json" "$temporary/service.json" "$temporary/invalid.json" <<'PYTHON'
import json
import sys
from pathlib import Path

defaulted = json.loads(Path(sys.argv[1]).read_text())
timeout = defaulted.get("spec", {}).get("template", {}).get("spec", {}).get("timeoutSeconds")
assert isinstance(timeout, int) and timeout > 0, "Knative defaulting admission did not run"
invalid = json.loads(Path(sys.argv[2]).read_text())
invalid["spec"]["template"]["metadata"] = {
    "annotations": {"autoscaling.knative.dev/min-scale": "-1"}
}
Path(sys.argv[3]).write_text(json.dumps(invalid))
PYTHON
if kubectl create --dry-run=server -f "$temporary/invalid.json" -o json >"$temporary/rejection.txt" 2>&1; then
    echo "Knative validation admission accepted a negative minimum scale" >&2
    exit 1
fi
if ! grep -F 'admission webhook "validation.webhook.serving.knative.dev" denied the request' "$temporary/rejection.txt"; then
    cat "$temporary/rejection.txt" >&2
    echo "The invalid probe failed without proving Knative validation admission" >&2
    exit 1
fi
echo "Knative defaulting and validation admission are active."
