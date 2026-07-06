{{/*
Generic Yeti worker Deployment (Celery worker/events/beat). Uses the api image
with a different command. Args:
  root, name, args (string literal YAML array), replicas, resources,
  nodeSelector, exports (bool), waitApi (bool)
*/}}
{{- define "yeti.workerDeployment" -}}
{{- $ctx := .root -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ printf "%s-%s" (include "yeti.fullname" $ctx) .name }}
  labels:
    app.kubernetes.io/component: {{ .name }}
    {{- include "yeti.labels" $ctx | nindent 4 }}
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/component: {{ .name }}
      {{- include "yeti.selectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        app.kubernetes.io/component: {{ .name }}
        {{- include "yeti.selectorLabels" $ctx | nindent 8 }}
      {{- if $ctx.Values.config.yetiConf }}
      annotations:
        checksum/yeti-conf: {{ $ctx.Values.config.yetiConf | sha256sum }}
      {{- end }}
    spec:
      serviceAccountName: {{ include "yeti.serviceAccountName" $ctx }}
      automountServiceAccountToken: {{ $ctx.Values.serviceAccount.automountServiceAccountToken }}
      {{- with $ctx.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml $ctx.Values.podSecurityContext | nindent 8 }}
      initContainers:
        {{- include "yeti.initWaitDeps" $ctx | nindent 8 }}
        {{- if .waitApi }}
        {{- include "yeti.initWaitApi" $ctx | nindent 8 }}
        {{- end }}
      containers:
        - name: {{ .name }}
          image: {{ include "yeti.image" (dict "img" $ctx.Values.api.image "root" $ctx) | quote }}
          imagePullPolicy: {{ $ctx.Values.image.pullPolicy }}
          args: {{ .args }}
          securityContext:
            {{- toYaml $ctx.Values.containerSecurityContext | nindent 12 }}
          env:
            {{- include "yeti.envs" $ctx | nindent 12 }}
          {{- include "yeti.envFrom" $ctx | nindent 10 }}
          resources:
            {{- toYaml .resources | nindent 12 }}
          {{- if or .exports $ctx.Values.config.yetiConf }}
          volumeMounts:
            {{- if .exports }}
            - name: exports
              mountPath: {{ $ctx.Values.exports.mountPath }}
            {{- end }}
            {{- include "yeti.confVolumeMount" $ctx | nindent 12 }}
          {{- end }}
      {{- if or .exports $ctx.Values.config.yetiConf }}
      volumes:
        {{- if .exports }}
        - name: exports
          persistentVolumeClaim:
            claimName: {{ $ctx.Values.exports.existingClaim | default (printf "%s-exports" (include "yeti.fullname" $ctx)) }}
        {{- end }}
        {{- include "yeti.confVolume" $ctx | nindent 8 }}
      {{- end }}
      {{- with .nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
