#!/bin/bash
# Collect cluster diagnostics for a failed continuous integration run.
#
# Every command is best effort: a failure here must never mask the original
# test failure, so the script never exits non-zero and never stops early.
#
# Usage: tests/collect_cluster_diagnostics.sh [namespace ...]
#
# The namespaces given as arguments are the component namespaces the calling
# workflow cares about. The infrastructure namespaces below are always
# collected because a stalled control plane, storage provisioner or ingress
# gateway explains most failures that look like an unrelated component timing
# out.

set -uo pipefail

OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-logs}"
INFRASTRUCTURE_NAMESPACES=("kube-system" "local-path-storage")

mkdir -p "$OUTPUT_DIRECTORY"

# Sampling mode records a time series instead of a single snapshot. A snapshot
# taken once the job has finished shows a settled cluster, so it cannot show how
# close to its limit the runner came while the workloads were starting. Start
# this in the background before the step under investigation.
if [ "${1:-}" = "sample" ]; then
    shift
    SAMPLE_INTERVAL_SECONDS="${1:-10}"
    SAMPLE_FILE="$OUTPUT_DIRECTORY/pressure-samples.tsv"

    printf 'timestamp\tload_average\tmemory_available_megabytes\tnot_ready_pods\tunbound_claims\tnode_pressure\n' \
        >"$SAMPLE_FILE"

    while true; do
        load_average=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "-")
        memory_available=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "-")

        not_ready_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null |
            awk '{split($3,ready,"/"); if (ready[1] != ready[2]) count++} END {print count+0}')
        unbound_claims=$(kubectl get persistentvolumeclaims --all-namespaces --no-headers 2>/dev/null |
            awk '$3 != "Bound" {count++} END {print count+0}')

        node_pressure=$(kubectl get nodes \
            -o jsonpath='{range .items[*]}{range .status.conditions[?(@.status=="True")]}{.type} {end}{end}' \
            2>/dev/null | tr ' ' '\n' | grep -E 'Pressure' | sort -u | tr '\n' ',' | sed 's/,$//')

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date -u +%H:%M:%S)" "$load_average" "${memory_available:--}" \
            "${not_ready_pods:--}" "${unbound_claims:--}" "${node_pressure:-none}" \
            >>"$SAMPLE_FILE"

        sleep "$SAMPLE_INTERVAL_SECONDS"
    done
fi

# Cluster-wide inventory.
kubectl get all --all-namespaces >"$OUTPUT_DIRECTORY/resources.txt" 2>&1 || true
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp \
    >"$OUTPUT_DIRECTORY/events.txt" 2>&1 || true

# Pod restart counts and placement. A pod that was ready earlier and is not
# ready now shows up here as a restart, which a describe of the current state
# alone does not reveal.
kubectl get pods --all-namespaces -o wide \
    >"$OUTPUT_DIRECTORY/pods-wide.txt" 2>&1 || true

# Node capacity and pressure conditions. MemoryPressure, DiskPressure and
# PIDPressure distinguish a genuinely stalled workload from a runner that ran
# out of capacity and started evicting healthy pods.
kubectl describe nodes >"$OUTPUT_DIRECTORY/nodes-describe.txt" 2>&1 || true
kubectl get nodes -o wide >"$OUTPUT_DIRECTORY/nodes-wide.txt" 2>&1 || true

# Storage. An unbound claim blocks every workload that mounts it, so the
# claims and volumes explain cascading readiness timeouts.
kubectl get persistentvolumeclaims --all-namespaces \
    >"$OUTPUT_DIRECTORY/persistentvolumeclaims.txt" 2>&1 || true
kubectl get persistentvolumes >"$OUTPUT_DIRECTORY/persistentvolumes.txt" 2>&1 || true

# Runner host capacity, which no kubectl command reports.
{
    echo "### uptime and load average"
    uptime
    echo
    echo "### memory"
    free -h
    echo
    echo "### disk"
    df -h
    echo
    echo "### processor count"
    nproc
} >"$OUTPUT_DIRECTORY/runner-host.txt" 2>&1 || true

for namespace in "${INFRASTRUCTURE_NAMESPACES[@]}" "$@"; do
    kubectl get namespace "$namespace" >/dev/null 2>&1 || continue

    kubectl describe pods -n "$namespace" \
        >"$OUTPUT_DIRECTORY/$namespace-pods.txt" 2>&1 || true

    for pod_name in $(kubectl get pods -n "$namespace" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do

        kubectl logs -n "$namespace" "$pod_name" --all-containers --tail=100 \
            >"$OUTPUT_DIRECTORY/$namespace-$pod_name.txt" 2>&1 || true

        # A restarted container only explains itself through the log of the
        # instance that died, so keep it when one exists.
        kubectl logs -n "$namespace" "$pod_name" --all-containers --previous \
            --tail=100 \
            >"$OUTPUT_DIRECTORY/$namespace-$pod_name-previous.txt" 2>&1 ||
            rm -f "$OUTPUT_DIRECTORY/$namespace-$pod_name-previous.txt"
    done
done

echo "Diagnostics written to $OUTPUT_DIRECTORY"
