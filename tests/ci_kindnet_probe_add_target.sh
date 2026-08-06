#!/bin/bash
# Throwaway continuous integration experiment instrumentation.
#
# Adds one more Service virtual address against direct Endpoint address pair to
# the target list that the paired probe DaemonSet reads. Use it once a component
# that owns an interesting Service has finished installing.
#
# Usage: tests/ci_kindnet_probe_add_target.sh <namespace> <service> <port> <path>
set -uo pipefail

PROBE_NAMESPACE="${CI_KINDNET_PROBE_NAMESPACE:-default}"

target_namespace="$1"
target_service="$2"
target_port="$3"
target_path="${4:-/}"

cluster_ip=$(kubectl get service "${target_service}" -n "${target_namespace}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
endpoint_address=$(kubectl get endpointslice -n "${target_namespace}" \
    -l "kubernetes.io/service-name=${target_service}" \
    -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || true)

if [ -z "${cluster_ip}" ] || [ -z "${endpoint_address}" ]; then
    echo "skipping ${target_namespace}/${target_service}: no Service virtual address or no backing Endpoint address yet"
    exit 0
fi

existing=$(kubectl get configmap ci-kindnet-probe-targets -n "${PROBE_NAMESPACE}" \
    -o jsonpath='{.data.targets\.csv}' 2>/dev/null || true)

# Command substitution removes the trailing newline, and without it the next
# entry would be appended to the last line rather than starting its own.
if [ -n "${existing}" ]; then
    existing="${existing}
"
fi

name="${target_namespace}-${target_service}"
if printf '%s' "${existing}" | grep -q "^${name},"; then
    echo "target ${name} is already present"
    exit 0
fi

updated="${existing}${name},http://${cluster_ip}:${target_port}${target_path},http://${endpoint_address}:${target_port}${target_path}
"

kubectl create configmap ci-kindnet-probe-targets \
    -n "${PROBE_NAMESPACE}" \
    --from-literal=targets.csv="${updated}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "added paired probe target ${name}"
printf '%s' "${updated}"
