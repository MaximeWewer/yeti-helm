{{/*
Environment variables passed to all Yeti app containers (api/tasks/events/beats).
Yeti reads YETI_* env vars (see yeti.conf.sample).
*/}}
{{- define "yeti.envs" -}}
- name: YETI_K8S_RUNTIME
  value: "true"
- name: YETI_SYSTEM_PLUGINS_PATH
  value: "./plugins"
{{- if .Values.bloomcheck.enabled }}
- name: YETI_BLOOM_BLOOMCHECK_ENDPOINT
  value: "http://{{ include "yeti.bloomcheck.fullname" . }}:{{ .Values.bloomcheck.service.port }}"
- name: YETI_BLOOM_FILTERS_DIR
  value: "/opt/yeti/bloomfilters"
{{- end }}
- name: YETI_REDIS_HOST
  value: {{ include "yeti.redis.host" . | quote }}
- name: YETI_REDIS_PORT
  value: {{ .Values.externalRedis.port | default 6379 | quote }}
- name: YETI_REDIS_DATABASE
  value: "0"
- name: YETI_ARANGODB_HOST
  value: {{ include "yeti.arangodb.fullname" . | quote }}
- name: YETI_ARANGODB_PORT
  value: "8529"
- name: YETI_ARANGODB_DATABASE
  value: {{ .Values.arangodb.database | quote }}
- name: YETI_ARANGODB_USERNAME
  value: "root"
- name: YETI_ARANGODB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "yeti.arangoSecretName" . }}
      key: password
- name: YETI_AUTH_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "yeti.secretName" . }}
      key: yeti-secret
{{- /* Tunable [auth] keys: emitted as env only when NOT using config.yetiConf.
       With yetiConf, these come from the merged file (base <- config.*, overridable
       by the overlay) — env would otherwise always win over the file. */}}
{{- if not .Values.config.yetiConf }}
- name: YETI_AUTH_ALGORITHM
  value: "HS256"
- name: YETI_AUTH_ACCESS_TOKEN_EXPIRE_MINUTES
  value: {{ .Values.config.auth.accessTokenExpireMinutes | quote }}
- name: YETI_AUTH_BROWSER_TOKEN_EXPIRE_MINUTES
  value: {{ .Values.config.auth.browserTokenExpireMinutes | quote }}
- name: YETI_AUTH_ENABLED
  value: {{ .Values.config.auth.enabled | quote }}
{{- end }}
- name: YETI_USER_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "yeti.secretName" . }}
      key: yeti-user
- name: YETI_SYSTEM_EXPORT_PATH
  value: {{ .Values.config.system.exportPath | quote }}
- name: YETI_AGENTS_ENABLED
  value: {{ .Values.agents.enabled | quote }}
{{- if .Values.agents.enabled }}
- name: YETI_AGENTS_HTTP_ROOT
  value: "http://{{ include "yeti.agents.fullname" . }}:{{ .Values.agents.service.port }}"
- name: YETI_AGENTS_WEBSOCKET_ROOT
  value: "ws://{{ include "yeti.agents.fullname" . }}:{{ .Values.agents.service.port }}"
{{- end }}
{{- /* Tunable [rbac] / [events] / [proxy]: env only without config.yetiConf
       (else sourced from the merged file). */}}
{{- if not .Values.config.yetiConf }}
- name: YETI_RBAC_ENABLED
  value: {{ .Values.config.rbac.enabled | quote }}
{{- if .Values.config.rbac.enabled }}
- name: YETI_RBAC_DEFAULT_GLOBAL_ROLE
  value: {{ .Values.config.rbac.defaultGlobalRole | quote }}
- name: YETI_RBAC_DEFAULT_ACLS
  value: {{ .Values.config.rbac.defaultAcls | quote }}
{{- end }}
- name: YETI_EVENTS_MEMORY_LIMIT
  value: {{ .Values.config.events.memoryLimit | quote }}
- name: YETI_EVENTS_KEEP_RATIO
  value: {{ .Values.config.events.keepRatio | quote }}
- name: YETI_EVENTS_CONSUMERS_CONCURRENCY
  value: {{ .Values.config.events.consumersConcurrency | quote }}
{{- with .Values.config.proxy.http }}
- name: YETI_PROXY_HTTP
  value: {{ . | quote }}
{{- end }}
{{- with .Values.config.proxy.https }}
- name: YETI_PROXY_HTTPS
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- if .Values.config.timesketch.enabled }}
- name: YETI_TIMESKETCH_ENDPOINT
  value: {{ required "config.timesketch.endpoint required when timesketch.enabled" .Values.config.timesketch.endpoint | quote }}
- name: YETI_TIMESKETCH_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ required "config.timesketch.existingSecret required" .Values.config.timesketch.existingSecret }}
      key: {{ .Values.config.timesketch.usernameKey }}
- name: YETI_TIMESKETCH_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.config.timesketch.existingSecret }}
      key: {{ .Values.config.timesketch.passwordKey }}
{{- end }}
{{- if .Values.config.oidc.enabled }}
- name: YETI_AUTH_MODULE
  value: "oidc"
- name: YETI_AUTH_OIDC_DISCOVERY_URL
  value: {{ .Values.config.oidc.discoveryUrl | quote }}
- name: YETI_AUTH_OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ required "config.oidc.existingSecret is required when oidc.enabled" .Values.config.oidc.existingSecret }}
      key: client-id
- name: YETI_AUTH_OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.config.oidc.existingSecret }}
      key: client-secret
{{- with .Values.config.oidc.allowedExtraAudiences }}
- name: YETI_AUTH_OIDC_EXTRA_CLIENT_AUDIENCES
  value: {{ . | quote }}
{{- end }}
{{- if .Values.ingress.enabled }}
- name: YETI_SYSTEM_WEBROOT
  value: {{ printf "https://%s" .Values.ingress.host | quote }}
{{- end }}
{{- end }}
{{- with .Values.extraEnv }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/*
envFrom block (Secrets/ConfigMaps) for feed API keys, MISP, proxy creds, AWS S3
credentials, etc. — anything not modelled as a structured value.
*/}}
{{- define "yeti.envFrom" -}}
{{- with .Values.extraEnvFrom }}
envFrom:
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/*
Init container: wait for Redis + ArangoDB DNS to resolve.
*/}}
{{- define "yeti.initWaitDeps" -}}
- name: wait-for-deps
  image: {{ .Values.config.initDependencyCheck.image | quote }}
  command: ["sh", "-c"]
  args:
    - |
      until nc -z -w3 {{ include "yeti.redis.host" . }} {{ .Values.externalRedis.port | default 6379 }}; do echo "waiting for Redis"; sleep 5; done
      until nc -z -w3 {{ include "yeti.arangodb.fullname" . }} 8529; do echo "waiting for ArangoDB"; sleep 5; done
      echo "dependencies reachable."
  securityContext:
    {{- toYaml .Values.containerSecurityContext | nindent 4 }}
{{- end }}

{{/*
Init container: wait for the Yeti API to be initialized (workers race on DB init).
*/}}
{{- define "yeti.initWaitApi" -}}
- name: wait-for-api
  image: {{ .Values.config.initDependencyCheck.image | quote }}
  command: ["sh", "-c"]
  args:
    - |
      until wget -q -O- http://{{ include "yeti.api.fullname" . }}:{{ .Values.api.service.port }}/openapi.json > /dev/null 2>&1; do
        echo "waiting for Yeti API..."; sleep 5
      done
      sleep 15
      echo "Yeti API ready."
  securityContext:
    {{- toYaml .Values.containerSecurityContext | nindent 4 }}
{{- end }}
