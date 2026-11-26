{{/* Common helpers for the chudmax-web chart. */}}

{{- define "chudmax-web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "chudmax-web.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "chudmax-web.labels" -}}
app.kubernetes.io/name: {{ include "chudmax-web.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "chudmax-web.selectorLabels" -}}
app.kubernetes.io/name: {{ include "chudmax-web.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "chudmax-web.image" -}}
{{- $i := .Values.image -}}
{{- if $i.digest -}}
{{- printf "%s@%s" $i.repository $i.digest -}}
{{- else -}}
{{- printf "%s:%s" $i.repository $i.tag -}}
{{- end -}}
{{- end -}}

{{- define "chudmax-web.allowedHosts" -}}
{{- $hosts := .Values.allowedHosts -}}
{{- if kindIs "string" $hosts -}}
{{- if eq $hosts "auto" -}}
{{- /* Short, mid and fully-qualified Service names (a same-namespace curl sends
       the SHORT one as Host — host_name() strips the port and lowercases), then
       loopback for port-forwards. */ -}}
{{- $full := include "chudmax-web.fullname" . -}}
{{- printf "%s,%s.%s.svc,%s.%s.svc.cluster.local,localhost,127.0.0.1" $full $full .Release.Namespace $full .Release.Namespace -}}
{{- else -}}
{{- $hosts -}}
{{- end -}}
{{- else -}}
{{- join "," $hosts -}}
{{- end -}}
{{- end -}}
