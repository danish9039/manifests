{{/*
Render a static Kustomize-generated KServe manifest file.
*/}}
{{- define "kubeflow-kserve.renderFile" -}}
{{- $root := .root -}}
{{- $content := $root.Files.Get .path -}}
{{- $content = replace "namespace: kubeflow\n" (printf "namespace: %s\n" ($root.Values.global.kubeflowNamespace | toString)) $content -}}
{{- $content = replace " kubeflow/" (printf " %s/" ($root.Values.global.kubeflowNamespace | toString)) $content -}}
{{- $content = replace ": kubeflow/" (printf ": %s/" ($root.Values.global.kubeflowNamespace | toString)) $content -}}
{{- $content = replace ".kubeflow.svc" (printf ".%s.svc" ($root.Values.global.kubeflowNamespace | toString)) $content -}}
{{- $content = replace "\"ingressGateway\": \"kubeflow/kubeflow-gateway\"" (printf "\"ingressGateway\": \"%s/kubeflow-gateway\"" ($root.Values.global.kubeflowNamespace | toString)) $content -}}
{{- $content = replace "\"localGateway\": \"knative-serving/knative-local-gateway\"" (printf "\"localGateway\": \"%s/knative-local-gateway\"" ($root.Values.global.knativeServingNamespace | toString)) $content -}}
{{- $content = replace "\"localGatewayService\": \"knative-local-gateway.istio-system.svc.cluster.local\"" (printf "\"localGatewayService\": \"knative-local-gateway.%s.svc.cluster.local\"" ($root.Values.global.istioNamespace | toString)) $content -}}
{{- $content -}}
{{- end -}}
