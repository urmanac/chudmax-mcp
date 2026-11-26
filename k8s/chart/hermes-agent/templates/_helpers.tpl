{{/* Common helpers for the hermes-agent chart. */}}

{{- define "hermes-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hermes-agent.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "hermes-agent.labels" -}}
app.kubernetes.io/name: {{ include "hermes-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "hermes-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hermes-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "hermes-agent.image" -}}
{{- $i := .Values.image -}}
{{- if $i.digest -}}
{{- printf "%s@%s" $i.repository $i.digest -}}
{{- else -}}
{{- printf "%s:%s" $i.repository $i.tag -}}
{{- end -}}
{{- end -}}

{{/* The Secret that carries API_SERVER_KEY: an existing one by name, or the
chart-created release Secret. Only meaningful when apiServer.enabled. */}}
{{- define "hermes-agent.apiKeySecretName" -}}
{{- .Values.apiServer.existingSecret | default (include "hermes-agent.fullname" .) -}}
{{- end -}}
