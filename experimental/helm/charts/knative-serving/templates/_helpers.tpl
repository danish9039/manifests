{{/*
Render a static Kustomize-generated Knative Serving manifest file.
*/}}
{{- define "kubeflow-knative-serving.renderFile" -}}
{{- $root := .root -}}
{{- $content := $root.Files.Get .path -}}
{{- $content = replace "kind: Namespace\nmetadata:\n  labels:" "kind: Namespace\nmetadata:\n  annotations:\n    helm.sh/resource-policy: keep\n  labels:" $content -}}
{{- $content = replace "kind: Image\nmetadata:\n  labels:" "kind: Image\nmetadata:\n  annotations:\n    helm.sh/resource-policy: keep\n  labels:" $content -}}
{{- $content = replace "kind: Certificate\nmetadata:\n  annotations:" "kind: Certificate\nmetadata:\n  annotations:\n    helm.sh/resource-policy: keep" $content -}}
{{- $content = replace "namespace: knative-serving\n" (printf "namespace: %s\n" ($root.Values.global.knativeServingNamespace | toString)) $content -}}
{{- $content = replace "name: knative-serving\n" (printf "name: %s\n" ($root.Values.global.knativeServingNamespace | toString)) $content -}}
{{- $content = replace "gateway.knative-serving." (printf "gateway.%s." ($root.Values.global.knativeServingNamespace | toString)) $content -}}
{{- $content = replace "local-gateway.knative-serving." (printf "local-gateway.%s." ($root.Values.global.knativeServingNamespace | toString)) $content -}}
{{- $content = replace "knative-local-gateway.istio-system.svc.cluster.local" (printf "knative-local-gateway.%s.svc.cluster.local" ($root.Values.global.istioNamespace | toString)) $content -}}
{{- $content = replace "istio-ingressgateway.istio-system.svc.cluster.local" (printf "istio-ingressgateway.%s.svc.cluster.local" ($root.Values.global.istioNamespace | toString)) $content -}}
{{- $content = replace "namespace: istio-system\n" (printf "namespace: %s\n" ($root.Values.global.istioNamespace | toString)) $content -}}
{{- $content = replace "kubernetes.io/metadata.name: istio-system" (printf "kubernetes.io/metadata.name: %s" ($root.Values.global.istioNamespace | toString)) $content -}}
{{- $content = replace "gateway.kubeflow.kubeflow-gateway" (printf "gateway.%s.kubeflow-gateway" ($root.Values.global.kubeflowNamespace | toString)) $content -}}
{{- $content -}}
{{- end -}}
