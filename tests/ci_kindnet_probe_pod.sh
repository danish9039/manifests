#!/bin/bash
# Throwaway continuous integration experiment instrumentation.
#
# Deploys the paired probe that answers the third question of the experiment:
# from one and the same source pod, is a request to a Service virtual address
# slower or less reliable than the identical request sent straight to the
# address of the pod that backs that Service?
#
# A difference between the two isolates the failure to the Service path, which
# is the path that the kindnet NFQUEUE handler sits on, rather than to the
# destination workload.
#
# The probe runs as a DaemonSet so that every node is a vantage point, and it
# reads its target list from a ConfigMap so that further Service and Endpoint
# pairs can be added once the components that own them are installed.
set -euo pipefail

OUTPUT_DIRECTORY="${1:-probe}"
PROBE_NAMESPACE="${CI_KINDNET_PROBE_NAMESPACE:-default}"
PROBE_IMAGE="${CI_KINDNET_PROBE_IMAGE:-curlimages/curl:8.11.1}"
PROBE_INTERVAL_SECONDS="${CI_KINDNET_PROBE_POD_INTERVAL_SECONDS:-3}"

mkdir -p "${OUTPUT_DIRECTORY}"

api_server_cluster_ip=$(kubectl get service kubernetes -n default \
    -o jsonpath='{.spec.clusterIP}')
api_server_endpoint_address=$(kubectl get endpointslice kubernetes -n default \
    -o jsonpath='{.endpoints[0].addresses[0]}' 2>/dev/null || true)
api_server_endpoint_port=$(kubectl get endpointslice kubernetes -n default \
    -o jsonpath='{.ports[0].port}' 2>/dev/null || true)

if [ -z "${api_server_endpoint_address}" ]; then
    api_server_endpoint_address=$(kubectl get endpoints kubernetes -n default \
        -o jsonpath='{.subsets[0].addresses[0].ip}')
    api_server_endpoint_port=$(kubectl get endpoints kubernetes -n default \
        -o jsonpath='{.subsets[0].ports[0].port}')
fi

echo "API server Service virtual address: ${api_server_cluster_ip}:443"
echo "API server backing Endpoint address: ${api_server_endpoint_address}:${api_server_endpoint_port}"

{
    echo "api_server_cluster_ip=${api_server_cluster_ip}"
    echo "api_server_endpoint_address=${api_server_endpoint_address}"
    echo "api_server_endpoint_port=${api_server_endpoint_port}"
} > "${OUTPUT_DIRECTORY}/paired-probe-targets.txt"

kubectl create configmap ci-kindnet-probe-targets \
    -n "${PROBE_NAMESPACE}" \
    --from-literal=targets.csv="apiserver,https://${api_server_cluster_ip}:443/version,https://${api_server_endpoint_address}:${api_server_endpoint_port}/version
" \
    --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ci-kindnet-probe
  namespace: ${PROBE_NAMESPACE}
  labels:
    app: ci-kindnet-probe
spec:
  selector:
    matchLabels:
      app: ci-kindnet-probe
  template:
    metadata:
      labels:
        app: ci-kindnet-probe
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: probe
        image: ${PROBE_IMAGE}
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 100
          capabilities:
            drop:
            - ALL
          seccompProfile:
            type: RuntimeDefault
        command:
        - /bin/sh
        - -c
        - |
          set -u
          interval=${PROBE_INTERVAL_SECONDS}
          format='%{http_code} %{time_total} %{time_connect} %{time_appconnect}'
          echo "timestamp,node,target,service_code,service_total,service_connect,service_appconnect,endpoint_code,endpoint_total,endpoint_connect,endpoint_appconnect"
          while true; do
            timestamp=\$(date +%s)
            while IFS=, read -r name service_url endpoint_url; do
              [ -n "\$name" ] || continue
              case "\$name" in '#'*) continue ;; esac
              service_result=\$(curl -s -k -o /dev/null --max-time 5 -w "\$format" "\$service_url" 2>/dev/null)
              [ -n "\$service_result" ] || service_result="000 -1 -1 -1"
              endpoint_result=\$(curl -s -k -o /dev/null --max-time 5 -w "\$format" "\$endpoint_url" 2>/dev/null)
              [ -n "\$endpoint_result" ] || endpoint_result="000 -1 -1 -1"
              echo "\$timestamp,\$NODE_NAME,\$name,\$service_result,\$endpoint_result" | tr ' ' ','
            done < /etc/ci-kindnet-probe/targets.csv
            sleep "\$interval"
          done
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: targets
          mountPath: /etc/ci-kindnet-probe
      volumes:
      - name: targets
        configMap:
          name: ci-kindnet-probe-targets
EOF

kubectl -n "${PROBE_NAMESPACE}" rollout status daemonset/ci-kindnet-probe --timeout=300s
kubectl -n "${PROBE_NAMESPACE}" get pods -l app=ci-kindnet-probe -o wide
