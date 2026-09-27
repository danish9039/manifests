#!/usr/bin/env bash
# Best-effort snapshots before release mutations and after failures. Call with
# an outer timeout as well, since the number of pods can vary.
set -u
directory=${1:?Pass an evidence directory}
release_namespace=${2:?Pass the release namespace}
release=${3:?Pass the release name}
shift 3
if [[ $# -eq 0 ]]; then set -- "$release_namespace"; fi
mkdir -p "$directory"

timeout --kill-after=2s 10s helm history "$release" --namespace "$release_namespace" \
    >"$directory/helm-history.txt" 2>&1 || true
for namespace in "$@"; do
    timeout --kill-after=2s 10s kubectl --request-timeout=5s get all -n "$namespace" -o yaml \
        >"$directory/$namespace-resources.yaml" 2>&1 || true
    timeout --kill-after=2s 10s kubectl --request-timeout=5s get events -n "$namespace" \
        --sort-by=.metadata.creationTimestamp >"$directory/$namespace-events.txt" 2>&1 || true
    timeout --kill-after=2s 10s kubectl --request-timeout=5s describe pods -n "$namespace" \
        >"$directory/$namespace-pods.txt" 2>&1 || true
    while IFS= read -r pod; do
        [[ -n "$pod" ]] || continue
        for previous in false true; do
            suffix=""
            if [[ "$previous" == true ]]; then suffix=-previous; fi
            timeout --kill-after=2s 10s kubectl --request-timeout=5s logs "$pod" -n "$namespace" \
                --all-containers=true --prefix=true --timestamps=true --tail=200 --previous="$previous" \
                >"$directory/$namespace-${pod#pod/}$suffix.log" 2>&1 || true
        done
    done < <(timeout --kill-after=2s 10s kubectl --request-timeout=5s get pods -n "$namespace" -o name \
        2>"$directory/$namespace-pod-list-errors.txt")
done
