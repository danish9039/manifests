#!/bin/bash
# Throwaway continuous integration experiment instrumentation.
#
# Applies the arm of the kindnet processor quota experiment that is selected in
# tests/ci_kindnet_arm.env, then records the resulting cgroup quota for every
# kindnet container so the applied state is verifiable from the artifacts alone.
set -uo pipefail

OUTPUT_DIRECTORY="${1:-probe}"
CLUSTER_NAME="${CI_KINDNET_PROBE_CLUSTER:-kubeflow}"
mkdir -p "${OUTPUT_DIRECTORY}"

CI_KINDNET_ARM="control"
# shellcheck disable=SC1091
if [ -f tests/ci_kindnet_arm.env ]; then
    . tests/ci_kindnet_arm.env
fi

echo "kindnet processor quota experiment arm: ${CI_KINDNET_ARM}"
echo "${CI_KINDNET_ARM}" > "${OUTPUT_DIRECTORY}/arm"

kubectl -n kube-system get daemonset kindnet -o yaml \
    > "${OUTPUT_DIRECTORY}/kindnet-daemonset-before.yaml" 2>&1 || true

if [ "${CI_KINDNET_ARM}" = "treatment" ]; then
    kubectl -n kube-system patch daemonset/kindnet --type=strategic \
        -p '{"spec":{"template":{"spec":{"containers":[{"name":"kindnet-cni","resources":{"requests":{"cpu":"100m"},"limits":{"cpu":null}}}]}}}}'
    kubectl -n kube-system rollout status daemonset/kindnet --timeout=180s
else
    echo "control arm: kindnet is left untouched at the KinD default limit"
fi

kubectl -n kube-system get daemonset kindnet -o yaml \
    > "${OUTPUT_DIRECTORY}/kindnet-daemonset-after.yaml" 2>&1 || true
kubectl -n kube-system get pods -l app=kindnet -o wide \
    > "${OUTPUT_DIRECTORY}/kindnet-pods-after-arm.txt" 2>&1 || true

# Record the effective processor quota from the kernel rather than from the
# object, because the object is the intent and the cgroup is the fact.
echo "node,cgroup_directory,cpu_max" > "${OUTPUT_DIRECTORY}/kindnet-cpu-max.csv"
for node in $(docker ps --format '{{.Names}}' \
        --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}"); do
    quota_line=$(docker exec "${node}" sh -c '
        container_id=$(crictl ps -q --name kindnet-cni --state Running 2>/dev/null | head -1)
        [ -n "${container_id}" ] || exit 0
        cgroup_directory=$(find /sys/fs/cgroup -type d -name "*${container_id}*" 2>/dev/null | head -1)
        [ -n "${cgroup_directory}" ] || exit 0
        if [ -f "${cgroup_directory}/cpu.max" ]; then
            echo "${cgroup_directory},$(tr " " "/" < "${cgroup_directory}/cpu.max")"
        elif [ -f "${cgroup_directory}/cpu.cfs_quota_us" ]; then
            echo "${cgroup_directory},$(cat "${cgroup_directory}/cpu.cfs_quota_us")/$(cat "${cgroup_directory}/cpu.cfs_period_us")"
        fi
    ' 2>/dev/null)
    echo "${node},${quota_line:-unresolved,unresolved}" >> "${OUTPUT_DIRECTORY}/kindnet-cpu-max.csv"
done

cat "${OUTPUT_DIRECTORY}/kindnet-cpu-max.csv"
