{{/*
Render a static Kustomize-generated manifest file while preserving the Go
templates embedded in Istio injector ConfigMaps.
*/}}
{{- define "kubeflow-istio.renderFile" -}}
{{- $root := .root -}}
{{- $content := $root.Files.Get .path -}}
{{- if eq $content "" -}}
{{- fail (printf "required manifest file %s is missing or empty" .path) -}}
{{- end -}}
{{- if .oauth2ProxyService -}}
{{- $portString := $root.Values.oauth2Proxy.port | toString -}}
{{- if not (regexMatch "^[0-9]+$" $portString) -}}
{{- fail "oauth2Proxy.port must be a decimal integer between 1 and 65535" -}}
{{- end -}}
{{- $port := atoi $portString -}}
{{- if or (lt $port 1) (gt $port 65535) -}}
{{- fail "oauth2Proxy.port must be a decimal integer between 1 and 65535" -}}
{{- end -}}
{{- $content = replace "service: oauth2-proxy.oauth2-proxy.svc.cluster.local" (printf "service: %s" ($root.Values.oauth2Proxy.service | toString)) $content -}}
{{- $content = regexReplaceAll "(service: [^\\n]+\\n[[:space:]]*port: )[0-9]+(\\n[[:space:]]*name: oauth2-proxy)" $content (printf "${1}%d${2}" $port) -}}
{{- end -}}
{{- $content -}}
{{- end -}}
