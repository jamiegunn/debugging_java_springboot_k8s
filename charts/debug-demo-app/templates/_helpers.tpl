{{- define "debug-demo-app.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "debug-demo-app.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "debug-demo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "debug-demo-app.oraclePasswordSecret" -}}
{{- if .Values.oracle.existingSecret -}}
{{ .Values.oracle.existingSecret }}
{{- else -}}
{{ include "debug-demo-app.fullname" . }}-secrets
{{- end -}}
{{- end -}}

{{- define "debug-demo-app.mqPasswordSecret" -}}
{{- if .Values.mq.existingSecret -}}
{{ .Values.mq.existingSecret }}
{{- else -}}
{{ include "debug-demo-app.fullname" . }}-secrets
{{- end -}}
{{- end -}}

{{- define "debug-demo-app.valkeyPasswordSecret" -}}
{{- if .Values.valkey.existingSecret -}}
{{ .Values.valkey.existingSecret }}
{{- else -}}
{{ include "debug-demo-app.fullname" . }}-secrets
{{- end -}}
{{- end -}}
