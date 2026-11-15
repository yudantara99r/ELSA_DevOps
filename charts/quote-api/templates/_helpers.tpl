{{- define "quote-api.name" -}}
quote-api
{{- end -}}

{{- define "quote-api.selector" -}}
app.kubernetes.io/name: {{ include "quote-api.name" . }}
{{- end -}}

{{- define "quote-api.labels" -}}
{{ include "quote-api.selector" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
