#!/bin/bash
# Throwaway continuous integration experiment instrumentation.
#
# Stops the sampler and collects everything that is not sampled continuously:
# the paired probe output from the pods, the kindnet container logs, the kindnet
# restart counts, and a final read of the processor cgroup and NFQUEUE state.
set -uo pipefail

OUTPUT_DIRECTORY="${1:-probe}"
PROBE_NAMESPACE="${CI_KINDNET_PROBE_NAMESPACE:-default}"
CLUSTER_NAME="${CI_KINDNET_PROBE_CLUSTER:-kubeflow}"

mkdir -p "${OUTPUT_DIRECTORY}"

if [ -f "${OUTPUT_DIRECTORY}/pid" ]; then
    kill "$(cat "${OUTPUT_DIRECTORY}/pid")" 2>/dev/null || true
fi
sleep 2

echo "=== paired Service and Endpoint probe output ==="
: > "${OUTPUT_DIRECTORY}/paired_probe.csv"
for pod in $(kubectl --request-timeout=30s -n "${PROBE_NAMESPACE}" get pods \
        -l app=ci-kindnet-probe -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl --request-timeout=120s -n "${PROBE_NAMESPACE}" logs "${pod}" --tail=-1 \
        >> "${OUTPUT_DIRECTORY}/paired_probe.csv" 2>/dev/null || true
done
wc -l "${OUTPUT_DIRECTORY}/paired_probe.csv" || true

echo "=== kindnet container logs, restart counts and final cgroup state ==="
kubectl --request-timeout=60s -n kube-system get pods -l app=kindnet -o wide \
    > "${OUTPUT_DIRECTORY}/kindnet-pods-final.txt" 2>&1 || true
kubectl --request-timeout=60s -n kube-system get pods -l app=kindnet \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.status.containerStatuses[0].lastState}{"\n"}{end}' \
    > "${OUTPUT_DIRECTORY}/kindnet-restarts.txt" 2>&1 || true
kubectl --request-timeout=60s -n kube-system describe pods -l app=kindnet \
    > "${OUTPUT_DIRECTORY}/kindnet-describe.txt" 2>&1 || true
for pod in $(kubectl --request-timeout=30s -n kube-system get pods -l app=kindnet \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl --request-timeout=120s -n kube-system logs "${pod}" --tail=4000 \
        > "${OUTPUT_DIRECTORY}/kindnet-${pod}.log" 2>&1 || true
    kubectl --request-timeout=60s -n kube-system logs "${pod}" --previous --tail=2000 \
        > "${OUTPUT_DIRECTORY}/kindnet-${pod}-previous.log" 2>&1 || true
done

# The following reads do not go through the API server, so they still work when
# the API server is the thing that is unreachable.
for node in $(docker ps --format '{{.Names}}' \
        --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}"); do
    {
        echo "===== ${node} kindnet processor cgroup ====="
        docker exec "${node}" sh -c '
            container_id=$(crictl ps -q --name kindnet-cni --state Running 2>/dev/null | head -1)
            cgroup_directory=$(find /sys/fs/cgroup -type d -name "*${container_id}*" 2>/dev/null | head -1)
            echo "container ${container_id}"
            echo "cgroup ${cgroup_directory}"
            cat "${cgroup_directory}/cpu.max" 2>/dev/null
            cat "${cgroup_directory}/cpu.stat" 2>/dev/null
            cat "${cgroup_directory}/memory.events" 2>/dev/null
        ' 2>&1
        echo "===== ${node} NFQUEUE ====="
        docker exec "${node}" cat /proc/net/netfilter/nfnetlink_queue 2>&1
        echo "===== ${node} nftables and iptables NFQUEUE rules ====="
        docker exec "${node}" sh -c 'nft list ruleset 2>/dev/null | grep -n -i -B2 queue | head -60' 2>&1
        docker exec "${node}" sh -c 'iptables-save 2>/dev/null | grep -i NFQUEUE | head -40' 2>&1
        echo "===== ${node} conntrack and dmesg tail ====="
        docker exec "${node}" sh -c 'cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null' 2>&1
        docker exec "${node}" sh -c 'dmesg 2>/dev/null | grep -iE "nf_queue|nfnetlink|nf_conntrack|oom" | tail -40' 2>&1
    } >> "${OUTPUT_DIRECTORY}/node-final-state.txt" 2>&1
done

echo "=== cluster state ==="
kubectl --request-timeout=60s get events --all-namespaces \
    --sort-by=.metadata.creationTimestamp > "${OUTPUT_DIRECTORY}/events.txt" 2>&1 || true
kubectl --request-timeout=60s get pods --all-namespaces -o wide \
    > "${OUTPUT_DIRECTORY}/pods.txt" 2>&1 || true

echo "=== summary ==="
python3 ./tests/ci_kindnet_probe_summary.py "${OUTPUT_DIRECTORY}" \
    | tee "${OUTPUT_DIRECTORY}/summary.txt" || true
