#!/bin/bash
# Throwaway continuous integration experiment instrumentation.
#
# Samples, once every few seconds, the measurements that decide whether the
# kindnet processor quota is the mechanism behind the flaky pipeline tests:
#
#   1. the processor cgroup statistics of every kindnet-cni container, read from
#      inside the KinD node containers, which is where throttling is visible.
#      Host level processor idle time says nothing about a container that is
#      capped at 100m, which is what an earlier measurement got wrong.
#   2. the NFQUEUE state from /proc/net/netfilter/nfnetlink_queue inside every
#      KinD node container, including the current queue depth.
#   3. the readiness of every Service backing set, so that a simultaneous
#      outage across unrelated Services is visible.
#
# The paired Service virtual address against direct Endpoint address probe runs
# inside a pod and is started separately by tests/ci_kindnet_probe_pod.sh.
set -uo pipefail

OUTPUT_DIRECTORY="${1:-probe}"
SAMPLE_INTERVAL_SECONDS="${CI_KINDNET_PROBE_INTERVAL_SECONDS:-5}"
ENDPOINT_SAMPLE_EVERY="${CI_KINDNET_PROBE_ENDPOINT_EVERY:-6}"
CLUSTER_NAME="${CI_KINDNET_PROBE_CLUSTER:-kubeflow}"

mkdir -p "${OUTPUT_DIRECTORY}"

CPU_STAT_FILE="${OUTPUT_DIRECTORY}/kindnet_cpu_stat.csv"
NFQUEUE_FILE="${OUTPUT_DIRECTORY}/nfqueue.csv"
ENDPOINT_FILE="${OUTPUT_DIRECTORY}/service_endpoints.csv"
NODE_LOAD_FILE="${OUTPUT_DIRECTORY}/node_load.csv"

echo "timestamp_ms,node,container_id,cpu_max,nr_periods,nr_throttled,throttled_usec" \
    > "${CPU_STAT_FILE}"
echo "timestamp_ms,node,queue_number,peer_portid,queue_total,copy_mode,copy_range,queue_dropped,user_dropped,id_sequence" \
    > "${NFQUEUE_FILE}"
echo "timestamp_ms,namespace,service,ready_addresses,total_addresses" \
    > "${ENDPOINT_FILE}"
echo "timestamp_ms,node,load_1,load_5,running_over_total" \
    > "${NODE_LOAD_FILE}"

now_milliseconds() {
    date +%s%3N
}

node_names() {
    docker ps --format '{{.Names}}' \
        --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" 2>/dev/null
}

# Reads everything that has to come from inside one KinD node container in a
# single docker exec, to keep the sampling cost low. The resolved cgroup
# directory is cached inside the node so the find runs once per container.
sample_node() {
    docker exec "$1" sh -c '
        container_id=$(crictl ps -q --name kindnet-cni --state Running 2>/dev/null | head -1)
        if [ -n "${container_id}" ]; then
            cache_file="/run/ci-kindnet-cgroup-${container_id}"
            cgroup_directory=""
            if [ -f "${cache_file}" ]; then
                cgroup_directory=$(cat "${cache_file}")
            fi
            if [ -z "${cgroup_directory}" ] || [ ! -d "${cgroup_directory}" ]; then
                cgroup_directory=$(find /sys/fs/cgroup -type d -name "*${container_id}*" 2>/dev/null | head -1)
                if [ -n "${cgroup_directory}" ]; then
                    echo "${cgroup_directory}" > "${cache_file}"
                fi
            fi
            echo "CONTAINER ${container_id}"
            if [ -n "${cgroup_directory}" ] && [ -d "${cgroup_directory}" ]; then
                if [ -f "${cgroup_directory}/cpu.max" ]; then
                    echo "CPUMAX $(tr " " "/" < "${cgroup_directory}/cpu.max")"
                elif [ -f "${cgroup_directory}/cpu.cfs_quota_us" ]; then
                    echo "CPUMAX $(cat "${cgroup_directory}/cpu.cfs_quota_us")/$(cat "${cgroup_directory}/cpu.cfs_period_us")"
                fi
                if [ -f "${cgroup_directory}/cpu.stat" ]; then
                    sed "s/^/STAT /" "${cgroup_directory}/cpu.stat"
                fi
            fi
        fi
        if [ -f /proc/net/netfilter/nfnetlink_queue ]; then
            sed "s/^/NFQUEUE /" /proc/net/netfilter/nfnetlink_queue
        fi
        echo "LOAD $(cat /proc/loadavg 2>/dev/null)"
    ' 2>/dev/null
}

sample_endpoints() {
    local timestamp="$1"
    local payload
    payload=$(kubectl --request-timeout=10s get endpointslices --all-namespaces -o json 2>/dev/null)
    if [ -z "${payload}" ]; then
        echo "${timestamp},KUBECTL_FAILED,KUBECTL_FAILED,-1,-1" >> "${ENDPOINT_FILE}"
        return
    fi
    printf '%s' "${payload}" | jq -r --arg timestamp "${timestamp}" '
        .items[]
        | [
            $timestamp,
            .metadata.namespace,
            (.metadata.labels["kubernetes.io/service-name"] // "unknown"),
            ([.endpoints[]? | select(.conditions.ready == true)] | length),
            ((.endpoints // []) | length)
          ]
        | @csv' 2>/dev/null | tr -d '"' >> "${ENDPOINT_FILE}"
}

iteration=0
while true; do
    timestamp=$(now_milliseconds)

    for node in $(node_names); do
        container_id="unresolved"
        cpu_max="unresolved"
        nr_periods=""
        nr_throttled=""
        throttled_usec=""

        while IFS= read -r line; do
            case "${line}" in
                "CONTAINER "*)
                    container_id="${line#CONTAINER }"
                    ;;
                "CPUMAX "*)
                    cpu_max="${line#CPUMAX }"
                    ;;
                "STAT nr_periods "*)
                    nr_periods="${line#STAT nr_periods }"
                    ;;
                "STAT nr_throttled "*)
                    nr_throttled="${line#STAT nr_throttled }"
                    ;;
                "STAT throttled_usec "*)
                    throttled_usec="${line#STAT throttled_usec }"
                    ;;
                "STAT throttled_time "*)
                    # Control group version one reports nanoseconds.
                    throttled_usec=$(( ${line#STAT throttled_time } / 1000 ))
                    ;;
                "NFQUEUE "*)
                    # shellcheck disable=SC2086
                    set -- ${line#NFQUEUE }
                    if [ "$#" -ge 8 ]; then
                        echo "${timestamp},${node},$1,$2,$3,$4,$5,$6,$7,$8" >> "${NFQUEUE_FILE}"
                    fi
                    ;;
                "LOAD "*)
                    # shellcheck disable=SC2086
                    set -- ${line#LOAD }
                    echo "${timestamp},${node},${1:-},${2:-},${4:-}" >> "${NODE_LOAD_FILE}"
                    ;;
            esac
        done <<< "$(sample_node "${node}")"

        if [ -n "${nr_periods}" ]; then
            echo "${timestamp},${node},${container_id},${cpu_max},${nr_periods},${nr_throttled},${throttled_usec}" \
                >> "${CPU_STAT_FILE}"
        else
            echo "${timestamp},${node},${container_id},${cpu_max},,," >> "${CPU_STAT_FILE}"
        fi
    done

    if [ $(( iteration % ENDPOINT_SAMPLE_EVERY )) -eq 0 ]; then
        sample_endpoints "${timestamp}"
    fi

    iteration=$(( iteration + 1 ))
    sleep "${SAMPLE_INTERVAL_SECONDS}"
done
