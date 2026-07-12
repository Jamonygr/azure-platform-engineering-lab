{{- define "ade-node-sample.name" -}}
ade-node-sample
{{- end }}

{{- define "ade-node-sample.labels" -}}
app.kubernetes.io/name: {{ include "ade-node-sample.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}
