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

{{/* Metrics: per-exporter switches (master switch AND per-component switch).
     Emit a non-empty string when on, so callers can use `if (include ...)`. */}}
{{- define "yeti.metrics.frontend" -}}
{{- if and .Values.metrics.enabled .Values.metrics.frontend.enabled -}}true{{- end -}}
{{- end }}
{{- define "yeti.metrics.celery" -}}
{{- if and .Values.metrics.enabled .Values.metrics.celery.enabled -}}true{{- end -}}
{{- end }}
{{- define "yeti.metrics.arangodb" -}}
{{- if and .Values.metrics.enabled .Values.metrics.arangodb.enabled .Values.arangodb.enabled -}}true{{- end -}}
{{- end }}

{{/* celery-exporter object name. */}}
{{- define "yeti.celeryExporter.fullname" -}}{{ printf "%s-celery-exporter" (include "yeti.fullname" .) }}{{- end }}

{{/* Annotation-based scrape config for an exporter Service. Args: root, port. */}}
{{- define "yeti.metrics.scrapeAnnotations" -}}
{{- if .root.Values.metrics.scrapeAnnotations }}
prometheus.io/scrape: "true"
prometheus.io/port: {{ .port | quote }}
prometheus.io/path: "/metrics"
{{- end }}
{{- end }}

{{/* Shared ServiceMonitor endpoint block. Args: root, port (name of the service
     port to scrape). */}}
{{- define "yeti.metrics.endpoint" -}}
{{- $m := .root.Values.metrics.serviceMonitor -}}
- port: {{ .port }}
  path: /metrics
  interval: {{ $m.interval }}
  {{- with $m.scrapeTimeout }}
  scrapeTimeout: {{ . }}
  {{- end }}
  honorLabels: {{ $m.honorLabels }}
  {{- with $m.relabelings }}
  relabelings:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $m.metricRelabelings }}
  metricRelabelings:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/* Celery worker command. The stock image entrypoint ("tasks") starts the
     worker WITHOUT task events, which celery-exporter needs, so when celery
     metrics are on we spell out the same upstream command plus `-E`.
     Upstream: uv run celery -A core.taskscheduler worker --loglevel=INFO
               --purge -P threads   (docker-entrypoint.sh, yeti 2.5.x) */}}
{{- define "yeti.tasks.args" -}}
{{- if and (include "yeti.metrics.celery" .) .Values.metrics.celery.workerTaskEvents -}}
["uv", "run", "celery", "-A", "core.taskscheduler", "worker", "--loglevel=INFO", "--purge", "-P", "threads", "-E"]
{{- else -}}
["tasks"]
{{- end -}}
{{- end }}

{{/* Redis service name (CloudPirates subchart uses <release>-redis by default). */}}
{{- define "yeti.redis.host" -}}
{{- if .Values.externalRedis.host -}}
{{- .Values.externalRedis.host -}}
{{- else -}}
{{- printf "%s-redis" .Release.Name -}}
{{- end -}}
{{- end }}

{{/* yeti.conf ConfigMap name. */}}
{{- define "yeti.confName" -}}{{ printf "%s-conf" (include "yeti.fullname" .) }}{{- end }}

{{/* Chart-generated base yeti.conf: the core sections derived from config.* —
     [system]/[auth]/[rbac]/[tag]/[arangodb]/[redis]/[bloom]/[events]/[agents]/
     [chromadb]/[proxy]. Their env is suppressed when config.yetiConf is set (see
     _env.tpl) so this file is their source of truth, and the user overlay
     (config.yetiConf) is merged ON TOP at runtime (overlay wins). Secrets are NOT
     here — arango password, auth SECRET_KEY, user password, timesketch/oidc creds
     stay as env and always win. Feeds/integrations are left to the overlay. */}}
{{- define "yeti.baseConf" -}}
[system]
export_path = {{ .Values.config.system.exportPath }}
plugins_path = {{ .Values.config.system.pluginsPath }}
logging = {{ .Values.config.system.logging }}
audit_logfile = {{ .Values.config.system.auditLogfile }}
template_dir = {{ .Values.config.system.templateDir }}
{{- if .Values.ingress.enabled }}
webroot = {{ printf "https://%s" .Values.ingress.host }}
{{- end }}
[auth]
module = {{ .Values.config.oidc.enabled | ternary "oidc" "local" }}
enabled = {{ .Values.config.auth.enabled | ternary "True" "False" }}
algorithm = HS256
access_token_expire_minutes = {{ .Values.config.auth.accessTokenExpireMinutes }}
browser_token_expire_minutes = {{ .Values.config.auth.browserTokenExpireMinutes }}
[rbac]
enabled = {{ .Values.config.rbac.enabled | ternary "True" "False" }}
default_global_role = {{ .Values.config.rbac.defaultGlobalRole }}
default_acls = {{ .Values.config.rbac.defaultAcls }}
{{- with .Values.config.tag.defaultExpiration }}
[tag]
default_tag_expiration = {{ . }}
{{- end }}
[arangodb]
host = {{ include "yeti.arangodb.fullname" . }}
port = 8529
username = root
database = {{ .Values.arangodb.database }}
[redis]
host = {{ include "yeti.redis.host" . }}
port = {{ .Values.externalRedis.port | default 6379 }}
database = 0
{{- if .Values.bloomcheck.enabled }}
[bloom]
bloomcheck_endpoint = http://{{ include "yeti.bloomcheck.fullname" . }}:{{ .Values.bloomcheck.service.port }}
filters_dir = /opt/yeti/bloomfilters
{{- end }}
[events]
memory_limit = {{ .Values.config.events.memoryLimit }}
keep_ratio = {{ .Values.config.events.keepRatio }}
consumers_concurrency = {{ .Values.config.events.consumersConcurrency }}
[agents]
enabled = {{ .Values.agents.enabled | ternary "True" "False" }}
{{- if .Values.agents.enabled }}
http_root = http://{{ include "yeti.agents.fullname" . }}:{{ .Values.agents.service.port }}
websocket_root = ws://{{ include "yeti.agents.fullname" . }}:{{ .Values.agents.service.port }}
{{- end }}
[chromadb]
path = {{ .Values.config.chromadb.path }}
[proxy]
http = {{ .Values.config.proxy.http }}
https = {{ .Values.config.proxy.https }}
{{- end }}

{{/* Roll pods when either the generated base or the user overlay changes. */}}
{{- define "yeti.confChecksum" -}}
{{- printf "%s|%s" (include "yeti.baseConf" .) .Values.config.yetiConf | sha256sum -}}
{{- end }}

{{/* initContainer: key-level merge of base.conf <- overlay.conf using Python's
     configparser (same parser Yeti uses), writing the result to the shared
     emptyDir. read([base, overlay]) merges per key with overlay winning; strict
     duplicate checks are per-source, so overlapping sections are fine. */}}
{{- define "yeti.confInitContainer" -}}
{{- if .Values.config.yetiConf }}
- name: merge-yeti-conf
  image: {{ .Values.config.confMergeImage | quote }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: ["python3", "-c"]
  args:
    - |
      import configparser
      c = configparser.ConfigParser(allow_no_value=True)
      c.read(["/conf-src/base.conf", "/conf-src/overlay.conf"], encoding="utf-8")
      with open("/conf/yeti.conf", "w", encoding="utf-8") as f:
          c.write(f)
  securityContext:
    {{- toYaml .Values.containerSecurityContext | nindent 4 }}
  volumeMounts:
    - name: yeti-conf-src
      mountPath: /conf-src
    - name: yeti-conf
      mountPath: /conf
{{- end }}
{{- end }}

{{/* Volume mount of the MERGED yeti.conf onto the app container (subPath keeps
     the rest of the image's /app intact). */}}
{{- define "yeti.confVolumeMount" -}}
{{- if .Values.config.yetiConf }}
- name: yeti-conf
  mountPath: /app/yeti.conf
  subPath: yeti.conf
  readOnly: true
{{- end }}
{{- end }}

{{/* Volumes: the source ConfigMap (base + overlay) and the emptyDir that the
     init container writes the merged file into. */}}
{{- define "yeti.confVolume" -}}
{{- if .Values.config.yetiConf }}
- name: yeti-conf
  emptyDir: {}
- name: yeti-conf-src
  configMap:
    name: {{ include "yeti.confName" . }}
{{- end }}
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
