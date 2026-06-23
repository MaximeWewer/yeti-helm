{{/* Chart name. */}}
{{- define "yeti.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name. */}}
{{- define "yeti.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "yeti.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels. */}}
{{- define "yeti.labels" -}}
helm.sh/chart: {{ include "yeti.chart" . }}
{{ include "yeti.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: yeti
{{- end }}

{{- define "yeti.selectorLabels" -}}
app.kubernetes.io/name: {{ include "yeti.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ServiceAccount name. */}}
{{- define "yeti.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "yeti.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* App Secret (yeti-secret / yeti-user). */}}
{{- define "yeti.secretName" -}}
{{- if .Values.config.existingSecret -}}
{{- .Values.config.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "yeti.fullname" .) -}}
{{- end -}}
{{- end }}

{{/* Dedicated ArangoDB root Secret (username/password only — required by the
     kube-arangodb operator bootstrap, which rejects secrets with extra keys). */}}
{{- define "yeti.arangoSecretName" -}}
{{- if .Values.arangodb.rootPasswordExistingSecret -}}
{{- .Values.arangodb.rootPasswordExistingSecret -}}
{{- else -}}
{{- printf "%s-arango-root" (include "yeti.fullname" .) -}}
{{- end -}}
{{- end }}

{{/* Component service / object names. */}}
{{- define "yeti.api.fullname" -}}{{ printf "%s-api" (include "yeti.fullname" .) }}{{- end }}
{{- define "yeti.frontend.fullname" -}}{{ printf "%s-frontend" (include "yeti.fullname" .) }}{{- end }}
{{- define "yeti.bloomcheck.fullname" -}}{{ printf "%s-bloomcheck" (include "yeti.fullname" .) }}{{- end }}
{{- define "yeti.agents.fullname" -}}{{ printf "%s-agents" (include "yeti.fullname" .) }}{{- end }}
{{- define "yeti.arangodb.fullname" -}}{{ printf "%s-arangodb" (include "yeti.fullname" .) }}{{- end }}

{{/* Redis service name (CloudPirates subchart uses <release>-redis by default). */}}
{{- define "yeti.redis.host" -}}
{{- if .Values.externalRedis.host -}}
{{- .Values.externalRedis.host -}}
{{- else -}}
{{- printf "%s-redis" .Release.Name -}}
{{- end -}}
{{- end }}

{{/* Full image ref helper: takes a dict {repository, tag, digest}. */}}
{{- define "yeti.image" -}}
{{- $img := .img -}}
{{- $reg := .root.Values.image.registry -}}
{{- $ref := $img.repository -}}
{{- if $reg -}}{{- $ref = printf "%s/%s" $reg $img.repository -}}{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref ($img.tag | default .root.Chart.AppVersion) -}}
{{- end -}}
{{- end }}
