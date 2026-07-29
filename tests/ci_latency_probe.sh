#!/usr/bin/env bash
# Throwaway continuous integration instrumentation for the intermittent
# installation failures. This file is an experiment and is not intended
# for merge into the upstream repository.
#
# It samples, every PROBE_INTERVAL_SECONDS seconds:
#
#   1. inject_ms   how long a server side dry run creation of a Pod in the
#                  injection enabled "kubeflow" namespace takes. This is the
#                  exact path that fails: Kubernetes API server calling the
#                  istiod sidecar injection webhook.
#   2. readyz_ms   how long "kubectl get --raw /readyz" takes. No istiod
#                  involvement.
#   3. istiod processor usage, read from the istiod Prometheus endpoint on
#      port 15014 through the API server pod proxy, and additionally from the
#      istiod container control group on the KinD node.
#
# Plus three controls that separate the hypotheses:
#
#   ping_ms      "kubectl get --raw /livez/ping", the cheapest possible API
#                server round trip. Separates transport and serving latency
#                from the cost of the readiness checks.
#   control_ms   server side dry run creation of the same Pod in the "default"
#                namespace, which has no injection label. This exercises the
#                whole admission chain except the istiod webhook.
#   runner processor busy percentage and load average, read from /proc on the
#   runner itself, which covers the whole KinD cluster because the nodes are
#   containers on that runner.
#
# Every 30 seconds it also scrapes the Kubernetes API server /metrics endpoint
# and extracts the server side view of webhook admission latency and of the
# priority and fairness queues.

set -uo pipefail

OUT_DIR="${1:-probe}"
INTERVAL="${PROBE_INTERVAL_SECONDS:-5}"
METRICS_EVERY="${PROBE_METRICS_EVERY:-6}"

mkdir -p "$OUT_DIR"
SAMPLES="$OUT_DIR/samples.csv"
POD_MANIFEST="$OUT_DIR/probe-pod.yaml"
PROBE_LOG="$OUT_DIR/probe.log"

exec >>"$PROBE_LOG" 2>&1

cat >"$POD_MANIFEST" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: latency-probe
  labels:
    experiment: latency-probe
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: probe
    image: registry.k8s.io/pause:3.10
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
YAML

now_ms() { date +%s%3N; }

# Runs the given command, discards its output, prints "<duration_ms> <exit_code>".
timed() {
  local start end rc
  start=$(now_ms)
  "$@" >/dev/null 2>&1
  rc=$?
  end=$(now_ms)
  printf '%s %s\n' "$((end - start))" "$rc"
}

# Total busy jiffies and total jiffies from the runner processor accounting.
read_proc_stat() {
  awk '/^cpu /{idle=$5+$6; total=0; for (i=2;i<=NF;i++) total+=$i; print total-idle, total; exit}' /proc/stat
}

ISTIOD_POD=""
ISTIOD_CGROUP_PATH=""
ISTIOD_NODE=""

resolve_istiod() {
  ISTIOD_POD=$(kubectl get pod -n istio-system -l app=istiod \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$ISTIOD_POD" ] || return 1
  ISTIOD_NODE=$(kubectl get pod -n istio-system "$ISTIOD_POD" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  local uid
  uid=$(kubectl get pod -n istio-system "$ISTIOD_POD" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null)
  if [ -n "$ISTIOD_NODE" ] && [ -n "$uid" ] && command -v docker >/dev/null 2>&1; then
    # Control group version 2 replaces the dashes of the pod identifier with
    # underscores in the slice name. Resolve the path once, because searching
    # the control group tree on every sample would itself add load.
    ISTIOD_CGROUP_PATH=$(docker exec "$ISTIOD_NODE" \
      find /sys/fs/cgroup -maxdepth 5 -type d -name "*pod${uid//-/_}*" 2>/dev/null | head -1)
  fi
  echo "resolved istiod pod=$ISTIOD_POD node=$ISTIOD_NODE cgroup=$ISTIOD_CGROUP_PATH"
}

istiod_cpu_seconds() {
  kubectl get --raw \
    "/api/v1/namespaces/istio-system/pods/${ISTIOD_POD}:15014/proxy/metrics" 2>/dev/null |
    awk '/^process_cpu_seconds_total /{print $2; exit}'
}

istiod_cgroup_usec() {
  [ -n "$ISTIOD_CGROUP_PATH" ] || return 0
  docker exec "$ISTIOD_NODE" cat "${ISTIOD_CGROUP_PATH}/cpu.stat" 2>/dev/null |
    awk '/^usage_usec /{print $2; exit}'
}

# Server side view, straight from the Kubernetes API server. Gives the mean
# admission duration of the injection webhook across every pod creation in the
# cluster, not only the probe, plus the priority and fairness queue depth.
scrape_apiserver_metrics() {
  local raw="$OUT_DIR/apiserver-metrics-$(date +%s).txt"
  if ! kubectl get --raw /metrics >"$raw" 2>/dev/null; then
    rm -f "$raw"
    return 1
  fi
  awk '
    /^apiserver_admission_webhook_admission_duration_seconds_(count|sum)\{/ &&
      /namespace.sidecar-injector.istio.io/ {
        if ($0 ~ /_count\{/) { c += $NF } else { s += $NF }
      }
    /^apiserver_flowcontrol_current_inqueue_requests\{/ { q += $NF }
    /^apiserver_flowcontrol_current_executing_requests\{/ { x += $NF }
    /^apiserver_request_terminations_total\{/ { t += $NF }
    END { printf "%d %.4f %d %d %d\n", c+0, s+0, q+0, x+0, t+0 }
  ' "$raw"
  gzip -f "$raw"
}

echo "probe starting, interval ${INTERVAL}s, output ${OUT_DIR}"
resolve_istiod || echo "istiod not resolvable yet"

echo "elapsed_s,iso_time,inject_ms,inject_rc,readyz_ms,readyz_rc,ping_ms,ping_rc,control_ms,control_rc,istiod_cpu_seconds,istiod_cpu_cores,istiod_cgroup_usec,istiod_cgroup_cores,runner_busy_pct,loadavg1,istiod_restarts,pods_not_running,webhook_calls,webhook_mean_ms,apf_inqueue,apf_executing,apiserver_terminations" >"$SAMPLES"

START_MS=$(now_ms)
prev_cpu_seconds=""
prev_cgroup_usec=""
prev_busy=""
prev_total=""
prev_sample_ms=""
prev_webhook_count=0
prev_webhook_sum=0
webhook_calls=""
webhook_mean_ms=""
apf_inqueue=""
apf_executing=""
apiserver_terminations=""
iteration=0

while :; do
  iteration=$((iteration + 1))
  sample_ms=$(now_ms)
  elapsed=$(((sample_ms - START_MS) / 1000))
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  read -r inject_ms inject_rc < <(timed kubectl create -n kubeflow \
    --dry-run=server --request-timeout=25s -f "$POD_MANIFEST")
  read -r readyz_ms readyz_rc < <(timed kubectl get --raw /readyz \
    --request-timeout=25s)
  read -r ping_ms ping_rc < <(timed kubectl get --raw /livez/ping \
    --request-timeout=25s)
  read -r control_ms control_rc < <(timed kubectl create -n default \
    --dry-run=server --request-timeout=25s -f "$POD_MANIFEST")

  [ -n "$ISTIOD_POD" ] || resolve_istiod >/dev/null

  cpu_seconds=$(istiod_cpu_seconds)
  cgroup_usec=$(istiod_cgroup_usec)
  read -r busy total < <(read_proc_stat)
  loadavg1=$(awk '{print $1; exit}' /proc/loadavg)

  istiod_restarts=$(kubectl get pod -n istio-system -l app=istiod \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
  pods_not_running=$(kubectl get pods --all-namespaces \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    --no-headers 2>/dev/null | wc -l)

  wall_s=1
  if [ -n "$prev_sample_ms" ]; then
    wall_s=$(awk -v a="$sample_ms" -v b="$prev_sample_ms" 'BEGIN{d=(a-b)/1000; print (d>0?d:1)}')
  fi

  istiod_cpu_cores=""
  if [ -n "$cpu_seconds" ] && [ -n "$prev_cpu_seconds" ]; then
    istiod_cpu_cores=$(awk -v a="$cpu_seconds" -v b="$prev_cpu_seconds" -v w="$wall_s" \
      'BEGIN{printf "%.3f", (a-b)/w}')
  fi

  istiod_cgroup_cores=""
  if [ -n "$cgroup_usec" ] && [ -n "$prev_cgroup_usec" ]; then
    istiod_cgroup_cores=$(awk -v a="$cgroup_usec" -v b="$prev_cgroup_usec" -v w="$wall_s" \
      'BEGIN{printf "%.3f", (a-b)/1000000/w}')
  fi

  runner_busy_pct=""
  if [ -n "$prev_busy" ]; then
    runner_busy_pct=$(awk -v b="$busy" -v pb="$prev_busy" -v t="$total" -v pt="$prev_total" \
      'BEGIN{d=t-pt; if (d>0) printf "%.1f", 100*(b-pb)/d}')
  fi

  if [ $((iteration % METRICS_EVERY)) -eq 1 ]; then
    if read -r c s q x term < <(scrape_apiserver_metrics); then
      webhook_calls=$((c - prev_webhook_count))
      if [ "$webhook_calls" -gt 0 ]; then
        webhook_mean_ms=$(awk -v s="$s" -v ps="$prev_webhook_sum" -v n="$webhook_calls" \
          'BEGIN{printf "%.1f", 1000*(s-ps)/n}')
      else
        webhook_mean_ms=""
      fi
      prev_webhook_count=$c
      prev_webhook_sum=$s
      apf_inqueue=$q
      apf_executing=$x
      apiserver_terminations=$term
    fi
  else
    webhook_calls=""
    webhook_mean_ms=""
    apf_inqueue=""
    apf_executing=""
    apiserver_terminations=""
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$elapsed" "$iso" "$inject_ms" "$inject_rc" "$readyz_ms" "$readyz_rc" \
    "$ping_ms" "$ping_rc" "$control_ms" "$control_rc" \
    "$cpu_seconds" "$istiod_cpu_cores" "$cgroup_usec" "$istiod_cgroup_cores" \
    "$runner_busy_pct" "$loadavg1" "$istiod_restarts" "$pods_not_running" \
    "$webhook_calls" "$webhook_mean_ms" "$apf_inqueue" "$apf_executing" \
    "$apiserver_terminations" >>"$SAMPLES"

  prev_cpu_seconds="$cpu_seconds"
  prev_cgroup_usec="$cgroup_usec"
  prev_busy="$busy"
  prev_total="$total"
  prev_sample_ms="$sample_ms"

  sleep "$INTERVAL"
done
