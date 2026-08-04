{{/*
Render a generated Kustomize payload verbatim. Helm does not send .Files.Get
content through the template renderer, so Go template delimiters that upstream
manifests legitimately contain are emitted as literal text.
*/}}
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

{{/*
Return an embedded document: the caller's value when set, otherwise the
generated upstream document. The generator writes documents with a single
trailing newline, which is removed so the inherited default matches the
Kustomize ConfigMap value exactly.

These values are documents, so the contract is a string. A map or list would
otherwise be rendered with Go's own formatting - a value of
"{menuLinks: []}" becomes the literal text "map[menuLinks:[]]" - which Helm
accepts and the application cannot parse. Reject anything that is not a string
rather than writing invalid configuration.
*/}}
{{- define "kubeflow-dashboard.document" -}}
{{- $root := index . "root" -}}
{{- $path := index . "path" -}}
{{- $value := index . "value" -}}
{{- $name := index . "name" -}}
{{- if not (or (kindIs "string" $value) (kindIs "invalid" $value)) -}}
{{- fail (printf "%s must be a string containing the document; got %s. Quote the value or pass it with --set-file." $name (kindOf $value)) -}}
{{- end -}}
{{- if and (kindIs "string" $value) (ne $value "") -}}
{{- $value -}}
{{- else -}}
{{- $document := $root.Files.Get $path -}}
{{- if eq ($document | trim) "" -}}
{{- fail (printf "required document %q is missing or empty; regenerate the chart payloads" $path) -}}
{{- end -}}
{{- trimSuffix "\n" $document -}}
{{- end -}}
{{- end -}}

{{/*
Component label sets, reproduced exactly as the Kustomize baseline renders them.
They appear in spec.selector.matchLabels, which Kubernetes treats as immutable,
so they must not be changed without a migration.
*/}}
{{- define "kubeflow-dashboard.centralDashboard.labels" -}}
app: kubeflow-dashboard
app.kubernetes.io/component: dashboard
app.kubernetes.io/managed-by: kustomize
app.kubernetes.io/name: centraldashboard
app.kubernetes.io/part-of: kubeflow-dashboard
{{- end -}}

{{- define "kubeflow-dashboard.profileController.labels" -}}
app: profile-controller
app.kubernetes.io/component: controller-manager
app.kubernetes.io/managed-by: kustomize
app.kubernetes.io/name: profile-controller
app.kubernetes.io/part-of: kubeflow-dashboard
{{- end -}}

{{- define "kubeflow-dashboard.podDefaultsWebhook.labels" -}}
app: poddefaults
app.kubernetes.io/component: poddefaults
app.kubernetes.io/managed-by: kustomize
app.kubernetes.io/name: poddefaults-webhook
app.kubernetes.io/part-of: kubeflow-dashboard
{{- end -}}

{{/*
Build a fully qualified image reference from the shared registry, a component
repository and the shared tag. An empty tag selects the chart appVersion.
*/}}
{{- define "kubeflow-dashboard.image" -}}
{{- $root := index . "root" -}}
{{- $repository := index . "repository" | toString -}}
{{- $registry := $root.Values.image.registry | toString | trimSuffix "/" -}}
{{- if eq $registry "" -}}
{{- fail "image.registry must not be empty" -}}
{{- end -}}
{{- if eq $repository "" -}}
{{- fail "every component image repository must be set" -}}
{{- end -}}
{{- $tag := $root.Values.image.tag | toString -}}
{{- if eq $tag "" -}}
{{- $tag = $root.Chart.AppVersion | toString -}}
{{- end -}}
{{- if eq $tag "" -}}
{{- fail "image.tag is empty and the chart declares no appVersion" -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- end -}}
