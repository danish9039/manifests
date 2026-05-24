{{/*
Render a static Kustomize-generated Kubeflow Trainer manifest file.
*/}}
{{- define "kubeflow-trainer.renderFile" -}}
{{- $root := .root -}}
{{- $content := $root.Files.Get .path -}}
{{- $content = replace "namespace: kubeflow-system\n" (printf "namespace: %s\n" ($root.Values.global.systemNamespace | toString)) $content -}}
{{- $content -}}
{{- end -}}
