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
        # instance that died. Query each restarted container separately: one
        # call for every container fails as soon as a single container has no
        # prior instance, which is the usual case when the application restarts
        # while its sidecar stays up.
        for container_name in $(kubectl get pod -n "$namespace" "$pod_name" \
            -o jsonpath='{.status.containerStatuses[?(@.restartCount>0)].name}' \
            2>/dev/null); do

            previous_log="$OUTPUT_DIRECTORY/$namespace-$pod_name-$container_name-previous.txt"
            kubectl logs -n "$namespace" "$pod_name" -c "$container_name" \
                --previous --tail=100 >"$previous_log" 2>&1 ||
                rm -f "$previous_log"
        done
    done
done

echo "Diagnostics written to $OUTPUT_DIRECTORY"
