{{- define "kubeflow-dashboard.generatedPayload" -}}
{{- $root := index . "root" -}}
{{- $path := index . "path" -}}
{{- $payload := $root.Files.Get $path -}}
{{- $hasResource := regexMatch "(?m)^apiVersion:[[:space:]]*[^[:space:]#]+" $payload -}}
{{- if or (eq ($payload | trim) "") (not $hasResource) -}}
{{- fail (printf "required generated payload %q is missing or empty; regenerate the chart payloads" $path) -}}
{{- end -}}
{{- $payload -}}
{{- end -}}
