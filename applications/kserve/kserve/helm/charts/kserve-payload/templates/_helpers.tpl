{{/*
Render a generated Kustomize payload verbatim. Helm does not send .Files.Get
content through the template renderer, so Go template delimiters that upstream
manifests legitimately contain are emitted as literal text rather than being
evaluated as part of this chart. KServe ships them in the inferenceservice-config
ingress settings and in every ClusterServingRuntime.
*/}}
{{- define "kserve.generatedPayload" -}}
{{- $root := index . "root" -}}
{{- $path := index . "path" -}}
{{- $payload := $root.Files.Get $path -}}
{{- $hasResource := regexMatch "(?m)^apiVersion:[[:space:]]*[^[:space:]#]+" $payload -}}
{{- if or (eq ($payload | trim) "") (not $hasResource) -}}
{{- fail (printf "required generated payload %q is missing or empty; regenerate the chart payloads" $path) -}}
{{- end -}}
{{- $payload -}}
{{- end -}}

{{/*
Render a generated payload without its ClusterServingRuntime objects. The
validating webhook clusterservingruntime.serving.kserve.io has failurePolicy:
Fail and is served by the kserve-controller-manager Deployment of the same
payload, so the API server rejects every ClusterServingRuntime until that
Deployment is ready. The second release revision therefore leaves them out.
The payload is filtered here, document by document, so the generated file
stays one verbatim copy of the Kustomize output.
*/}}
{{- define "kserve.generatedPayloadWithoutClusterServingRuntimes" -}}
{{- $documents := list -}}
{{- range $document := splitList "\n---\n" (include "kserve.generatedPayload" .) -}}
{{- if not (regexMatch "(?m)^kind: ClusterServingRuntime$" $document) -}}
{{- $documents = append $documents $document -}}
{{- end -}}
{{- end -}}
{{- join "\n---\n" $documents -}}
{{- end -}}
