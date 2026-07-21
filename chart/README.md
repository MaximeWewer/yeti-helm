# Yeti Helm

Helm chart for [Yeti](https://yeti-platform.io/) (CTI platform: observables / TTPs / campaigns).

Derived from the [OSDFIR Yeti](https://github.com/google/osdfir-infrastructure/tree/main/charts/osdfir-infrastructure/charts/yeti) sub-chart, **isolated** and **improved**: operator-first dependencies, NetworkPolicy, PDB, hardened securityContext, `existingSecret`, schema, helm-docs.

## Architecture

Components (image `yetiplatform/*`):

| Component | Type | Role |
|-----------|------|------|
| `frontend` | Deployment | Vue UI served by nginx (reverse-proxies `/api/v2`, `/docs` → api) |
| `api` | Deployment | FastAPI API (`webserver`), port 8000 |
| `tasks` | Deployment | Celery worker (`tasks`) |
| `events` | Deployment | Celery events worker (`events-tasks`) |
| `beats` | Deployment | Celery beat (`tasks-beat`) — **singleton** |
| `bloomcheck` | StatefulSet | Bloom-filter service (upstream `dev` tag) |
| `agents` | StatefulSet | Agents HTTP/WS service (:8888, sqlite) — **optional** (`agents.enabled`) |

**Bundled dependencies:**

- **ArangoDB** (graph DB) via the **[kube-arangodb](https://github.com/arangodb/kube-arangodb)** operator — `ArangoDeployment` CR in `Single` mode, internal TLS disabled (http:8529), root password *bootstrapped* from the `password` key of the chart secret.
- **Redis** (Celery broker) via the **[CloudPirates redis](https://github.com/CloudPirates-io/helm-charts/tree/main/charts/redis)** chart (OCI dependency). **Auth disabled**: Yeti does not support Redis auth; the broker is protected by NetworkPolicy.

## Prerequisites

- A Kubernetes cluster, Helm **3+**.
- **kube-arangodb operator** installed cluster-wide (this chart ships only the `ArangoDeployment` CR):
  ```sh
  helm install kube-arangodb \
    https://github.com/arangodb/kube-arangodb/releases/download/<ver>/kube-arangodb-<ver>.tgz \
    --set "operator.features.deployment=true"
  ```
- **Redis** is pulled as a bundled dependency — run `helm dependency build .` before installing.
- Optional, only if you enable the matching feature:
  - A `ReadWriteMany` StorageClass (NFS/EFS) — for the shared `exports` volume on multi-node clusters.

## Install

```sh
helm dependency build .
helm install yeti . -n cti --create-namespace
```

Secrets are generated automatically (keys `password` / `yeti-secret` / `yeti-user`) when `config.existingSecret` is not provided. Initial admin password:

```sh
kubectl get secret -n cti yeti-secret -o jsonpath='{.data.yeti-user}' | base64 -d
```

**Secret sourcing** (highest precedence first):

1. `config.existingSecret` — reference a pre-existing Secret (ESO/Vault). Recommended in production.
2. `config.secrets.{yetiSecret,yetiUser,arangoPassword}` — **inline** values (per key). Use when you have no secret manager, especially under **ArgoCD**: the generated-secret path relies on `lookup`, which returns empty during Argo's diff/dry-run, so the random value **churns on every sync** and passwords change. Inline values make the Secret deterministic.
3. Auto-generated (`randAlphaNum` + `lookup` to preserve across upgrades) — the default when nothing above is set. Stable under `helm upgrade`, **unstable under ArgoCD** (see above).

## Security

- Hardened `containerSecurityContext`: `allowPrivilegeEscalation: false`, `drop: [ALL]`, `privileged: false` (+ `seccompProfile: RuntimeDefault` at the pod level).
- `automountServiceAccountToken: false`.
- **`podSecurityContext.runAsNonRoot` defaults to `false`**: the `yetiplatform/*` images have no verified non-root uid. After testing (check the image uid), switch to `true` + a suitable `runAsUser`, and `containerSecurityContext.readOnlyRootFilesystem: true` if the app supports it.
- NetworkPolicy: frontend ingress restricted (`networkPolicy.frontendAllowedFrom`), intra-app traffic limited (api 8000, bloomcheck 8100). **Egress**: DNS + intra-namespace. Yeti fetches **external feeds** (tasks) → add outbound egress (443) via `networkPolicy.extraEgress`.
- Secrets never in cleartext in the values: use `config.existingSecret` (ESO/Vault) in production.

## Advanced configuration

Yeti maps `yeti.conf` onto `YETI_<SECTION>_<KEY>` environment variables. The chart exposes the structured sections via `config.*` and delegates the rest (feed API keys, MISP, creds) to `extraEnvFrom`.

You can also supply a raw `yeti.conf` via `config.yetiConf` (INI, à la [`yeti.conf.sample`](https://github.com/yeti-platform/yeti/blob/main/yeti.conf.sample)). It is **merged** over a base `yeti.conf` generated from `config.*`: a `merge-yeti-conf` initContainer runs `configparser.read([base, overlay])` (the same parser Yeti uses) — a **key-level merge where your file wins** — and writes the result to `/app/yeti.conf` on the `api`/`tasks`/`events`/`beats`/`agents` pods. A checksum annotation rolls pods when the base or overlay changes.

> **The base covers all core sections**, generated from `config.*`: `[system]`, `[auth]`, `[rbac]`, `[tag]`, `[arangodb]`, `[redis]`, `[bloom]`, `[events]`, `[agents]`, `[chromadb]`, `[proxy]`. When `yetiConf` is set the chart stops emitting the `YETI_*` env for these, so the merged file is authoritative — `config.yetiConf` **>** `config.*`, and keys you omit keep the `config.*` base value. Any extra section (feeds `[vt]`/`[otx]`/`[misp_1]`, `[dfiq]`, `[github]`, `[datadog]`, …) is merged in as-is.
>
> **Secrets stay env-managed and always win — never override via `yetiConf`:** the ArangoDB password, auth `SECRET_KEY`, the initial user password, and `[timesketch]`/`[oidc]` credentials (injected from Secrets). Prefer `extraEnvFrom` (Secret) for feed API keys over plaintext here. The merge uses `config.confMergeImage` (default `python:3.14-alpine`, stdlib only).

| yeti.conf section | Exposed via | Notes |
|-------------------|-------------|-------|
| `[rbac]` | `config.rbac.{enabled,defaultGlobalRole,defaultAcls}` | RBAC disabled upstream by default → **`enabled: true` recommended** for shared deployments |
| `[events]` | `config.events.{memoryLimit,keepRatio,consumersConcurrency}` | Events worker tuning |
| `[agents]` | `agents.enabled` | **`false` by default**. When `true`: deploys the agents StatefulSet+Service **and** wires `YETI_AGENTS_ENABLED/HTTP_ROOT/WEBSOCKET_ROOT` |
| `[proxy]` | `config.proxy.{http,https}` | Outbound proxy for feeds (`socks5://…` / `http://…`) |
| `[system] export_path` | `config.system.exportPath` | Local (PVC) **or** `s3://bucket/prefix` (`AWS_*` creds via `extraEnvFrom`, image with the `s3` extra) |
| `[timesketch]` | `config.timesketch.{enabled,endpoint,existingSecret}` | Optional integration (Timesketch = backlog) |
| `[misp]`, `[vt]`, `[otx]`, `[shodan]`, `[censys]`, `[abuseIPDB]`, `[dnsdb]`, `[dfiq]`, `[github]`, `[datadog]`, … | **`extraEnvFrom`** or **`config.yetiConf`** | Long tail. Secret via `extraEnvFrom` (preferred for keys) or raw INI via `config.yetiConf` |
| `[system]`, `[auth]`, `[rbac]`, `[tag]`, `[arangodb]`, `[redis]`, `[bloom]`, `[events]`, `[agents]`, `[chromadb]`, `[proxy]` | `config.*` **base**, overridable by **`config.yetiConf`** | Generated into `base.conf` from `config.*`; when `yetiConf` is set it wins per key at merge time |
| ArangoDB password, auth `SECRET_KEY`, user password, `[timesketch]`/`[oidc]` creds | Secret via the chart (env) | Injected from Secrets — **not** overridable via `config.yetiConf` |

Feeds + S3 example:

```sh
kubectl create secret generic yeti-feeds -n cti \
  --from-literal=YETI_VT_KEY=... \
  --from-literal=YETI_SHODAN_API_KEY=... \
  --from-literal=YETI_MISP_INSTANCES=misp_1 \
  --from-literal=YETI_MISP_1_URL=https://misp --from-literal=YETI_MISP_1_KEY=... \
  --from-literal=AWS_ACCESS_KEY_ID=... --from-literal=AWS_SECRET_ACCESS_KEY=...

helm upgrade yeti . -n cti \
  --set config.system.exportPath=s3://my-bucket/yeti \
  --set 'extraEnvFrom[0].secretRef.name=yeti-feeds'
```

## Metrics / Prometheus

**Yeti ships no Prometheus endpoint.** Neither the api (FastAPI/uvicorn), the Celery workers, the agents service nor `bloomcheck` (Go) expose `/metrics` — upstream's only observability hook is a *push-based* Datadog events plugin (`[datadog]`). The chart therefore wires exporters **around** the stack, all behind `metrics.enabled` (off by default) plus a per-target switch:

| Target | How | Port | Value |
|--------|-----|------|-------|
| `frontend` (nginx) | pod-local `stub_status` listener added to the chart-managed nginx conf + [`nginx-prometheus-exporter`](https://github.com/nginxinc/nginx-prometheus-exporter) sidecar. Covers the UI **and** the `/api/v2` proxy traffic (rps, statuses, connections). | 9113 | `metrics.frontend.enabled` |
| `tasks` (Celery) | [`celery-exporter`](https://github.com/danihodovic/celery-exporter) Deployment subscribed to the Redis broker event stream (`celery_task_*`, `celery_worker_*`, queue length). | 9808 | `metrics.celery.enabled` |
| ArangoDB | **native** ArangoDB metrics, enabled through `ArangoDeployment.spec.metrics` (the operator injects the exporter and, with `serviceMonitor.enabled`, its own ServiceMonitor). | 9101 | `metrics.arangodb.enabled` |
| Redis | owned by the subchart | 9121 | `redis.metrics.enabled` (+ `redis.metrics.serviceMonitor.enabled`) |

`api`, `agents`, `events` and `bloomcheck` have **no** exporter: there is nothing to scrape upstream, and the frontend exporter already accounts for the HTTP traffic that reaches the API.

```sh
helm upgrade yeti . -n cti \
  --set metrics.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set redis.metrics.enabled=true --set redis.metrics.serviceMonitor.enabled=true
```

- **ServiceMonitors** (`metrics.serviceMonitor.enabled`) need the `monitoring.coreos.com` CRDs. If your Prometheus uses a `serviceMonitorSelector`, add the matching label via `metrics.serviceMonitor.labels` (e.g. `release: kube-prometheus-stack`).
- Without the Prometheus Operator, set `metrics.scrapeAnnotations=true` to get `prometheus.io/{scrape,port,path}` on the exporter Services.
- **`-E` on the worker**: Celery only emits task events when the worker is started with `-E`, which the stock `tasks` entrypoint does not do. With `metrics.celery.workerTaskEvents=true` (default) the chart replaces the `tasks` command with the same upstream celery invocation plus `-E`. Set it to `false` to keep the stock entrypoint — worker/queue metrics keep working, per-task metrics (`celery_task_*`) do not.
- `celery_task_sent_total` stays empty: it depends on the *producer* setting `task_send_sent_event`, which Yeti does not enable in `core/taskscheduler.py`. Everything else (`celery_task_received/started/succeeded/failed/runtime`, `celery_worker_*`, `celery_queue_length`) works.
- **NetworkPolicy**: scraping is denied by default. Declare your Prometheus peers in `metrics.networkPolicy.allowedFrom` (standard `NetworkPolicyPeer` items), e.g. `namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: monitoring}}`.

## Notes

- `beats` (Celery beat) is a singleton — do not scale it.
- `exports` must be **ReadWriteMany** (NFS/EFS) on multi-node clusters (shared by api/tasks/events).
- Yeti does not support Redis auth → `redis.auth.enabled=false` is required.
- ArangoDB root password = the `password` key of the secret (used both by the operator at bootstrap and by Yeti via `YETI_ARANGODB_PASSWORD`).

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| oci://registry-1.docker.io/cloudpirates | redis | 0.32.* |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| agents.affinity | object | `{}` |  |
| agents.dbPath | string | `"/data/sessions.db"` |  |
| agents.enabled | bool | `false` |  |
| agents.image.digest | string | `""` |  |
| agents.image.repository | string | `"yetiplatform/yeti-agents"` |  |
| agents.image.tag | string | `"2.5.1"` |  |
| agents.nodeSelector | object | `{}` |  |
| agents.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| agents.persistence.enabled | bool | `true` |  |
| agents.persistence.size | string | `"1Gi"` |  |
| agents.persistence.storageClass | string | `""` |  |
| agents.resources | object | `{}` |  |
| agents.service.port | int | `8888` |  |
| agents.tolerations | list | `[]` |  |
| api.affinity | object | `{}` |  |
| api.image.digest | string | `""` |  |
| api.image.repository | string | `"yetiplatform/yeti"` |  |
| api.image.tag | string | `"2.5.1"` |  |
| api.nodeSelector | object | `{}` |  |
| api.replicas | int | `1` |  |
| api.resources | object | `{}` |  |
| api.service.port | int | `8000` |  |
| api.tolerations | list | `[]` |  |
| arangodb.database | string | `"yeti"` |  |
| arangodb.enabled | bool | `true` |  |
| arangodb.image | string | `"arangodb/arangodb:3.11.8"` |  |
| arangodb.mode | string | `"Single"` |  |
| arangodb.overrideDetectedTotalMemory | string | `""` |  |
| arangodb.persistence.size | string | `"8Gi"` |  |
| arangodb.persistence.storageClass | string | `""` |  |
| arangodb.resources.limits.cpu | string | `"2"` |  |
| arangodb.resources.limits.memory | string | `"2Gi"` |  |
| arangodb.resources.requests.cpu | string | `"250m"` |  |
| arangodb.resources.requests.memory | string | `"1Gi"` |  |
| arangodb.rootPasswordExistingSecret | string | `""` |  |
| beats.affinity | object | `{}` |  |
| beats.enabled | bool | `true` |  |
| beats.nodeSelector | object | `{}` |  |
| beats.resources | object | `{}` |  |
| beats.tolerations | list | `[]` |  |
| bloomcheck.affinity | object | `{}` |  |
| bloomcheck.enabled | bool | `true` |  |
| bloomcheck.image.digest | string | `""` |  |
| bloomcheck.image.repository | string | `"yetiplatform/bloomcheck"` |  |
| bloomcheck.image.tag | string | `"dev"` |  |
| bloomcheck.nodeSelector | object | `{}` |  |
| bloomcheck.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| bloomcheck.persistence.enabled | bool | `true` |  |
| bloomcheck.persistence.size | string | `"2Gi"` |  |
| bloomcheck.persistence.storageClass | string | `""` |  |
| bloomcheck.resources | object | `{}` |  |
| bloomcheck.service.port | int | `8100` |  |
| bloomcheck.tolerations | list | `[]` |  |
| config.auth.accessTokenExpireMinutes | int | `10000` |  |
| config.auth.browserTokenExpireMinutes | int | `43200` |  |
| config.auth.enabled | bool | `true` |  |
| config.chromadb.path | string | `"/data/chromadb"` |  |
| config.confMergeImage | string | `"python:3.14-alpine"` |  |
| config.createUser | bool | `true` |  |
| config.events.consumersConcurrency | int | `2` |  |
| config.events.keepRatio | float | `0.9` |  |
| config.events.memoryLimit | int | `64` |  |
| config.existingSecret | string | `""` |  |
| config.imagePullPolicy | string | `"IfNotPresent"` |  |
| config.initDependencyCheck.image | string | `"busybox:1.36"` |  |
| config.oidc.allowedExtraAudiences | string | `""` |  |
| config.oidc.discoveryUrl | string | `"https://example.com/.well-known/openid-configuration"` |  |
| config.oidc.enabled | bool | `false` |  |
| config.oidc.existingSecret | string | `""` |  |
| config.proxy.http | string | `""` |  |
| config.proxy.https | string | `""` |  |
| config.rbac.defaultAcls | string | `"All users"` |  |
| config.rbac.defaultGlobalRole | string | `"writer"` |  |
| config.rbac.enabled | bool | `false` |  |
| config.secrets.arangoPassword | string | `""` |  |
| config.secrets.yetiSecret | string | `""` |  |
| config.secrets.yetiUser | string | `""` |  |
| config.system.auditLogfile | string | `"/var/log/yeti_audit.log"` |  |
| config.system.exportPath | string | `"/opt/yeti/exports"` |  |
| config.system.logging | string | `"/var/log/yeti_user_activity.log"` |  |
| config.system.pluginsPath | string | `"./plugins"` |  |
| config.system.templateDir | string | `"/opt/yeti/templates"` |  |
| config.tag.defaultExpiration | string | `""` |  |
| config.timesketch.enabled | bool | `false` |  |
| config.timesketch.endpoint | string | `""` |  |
| config.timesketch.existingSecret | string | `""` |  |
| config.timesketch.passwordKey | string | `"timesketch-password"` |  |
| config.timesketch.usernameKey | string | `"timesketch-user"` |  |
| config.yetiConf | string | `""` |  |
| containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| containerSecurityContext.privileged | bool | `false` |  |
| containerSecurityContext.readOnlyRootFilesystem | bool | `false` |  |
| events.affinity | object | `{}` |  |
| events.enabled | bool | `true` |  |
| events.nodeSelector | object | `{}` |  |
| events.replicas | int | `1` |  |
| events.resources | object | `{}` |  |
| events.tolerations | list | `[]` |  |
| exports.accessModes[0] | string | `"ReadWriteMany"` |  |
| exports.enabled | bool | `true` |  |
| exports.existingClaim | string | `""` |  |
| exports.mountPath | string | `"/opt/yeti/exports"` |  |
| exports.size | string | `"5Gi"` |  |
| exports.storageClass | string | `""` |  |
| externalRedis.host | string | `""` |  |
| externalRedis.port | int | `6379` |  |
| extraEnv | list | `[]` |  |
| extraEnvFrom | list | `[]` |  |
| frontend.affinity | object | `{}` |  |
| frontend.containerPort | int | `8080` |  |
| frontend.image.digest | string | `""` |  |
| frontend.image.repository | string | `"yetiplatform/yeti-frontend"` |  |
| frontend.image.tag | string | `"2.5.1"` |  |
| frontend.nodeSelector | object | `{}` |  |
| frontend.replicas | int | `1` |  |
| frontend.resources | object | `{}` |  |
| frontend.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| frontend.securityContext.capabilities.add[0] | string | `"CHOWN"` |  |
| frontend.securityContext.capabilities.add[1] | string | `"SETUID"` |  |
| frontend.securityContext.capabilities.add[2] | string | `"SETGID"` |  |
| frontend.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| frontend.securityContext.privileged | bool | `false` |  |
| frontend.service.port | int | `80` |  |
| frontend.service.type | string | `"ClusterIP"` |  |
| frontend.tolerations | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.registry | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.host | string | `"yeti.example.com"` |  |
| ingress.tls | list | `[]` |  |
| metrics.arangodb.enabled | bool | `true` |  |
| metrics.arangodb.port | int | `9101` |  |
| metrics.celery.enabled | bool | `true` |  |
| metrics.celery.extraArgs | list | `[]` |  |
| metrics.celery.image.digest | string | `""` |  |
| metrics.celery.image.repository | string | `"danihodovic/celery-exporter"` |  |
| metrics.celery.image.tag | string | `"0.12.2"` |  |
| metrics.celery.port | int | `9808` |  |
| metrics.celery.resources | object | `{}` |  |
| metrics.celery.workerTaskEvents | bool | `true` |  |
| metrics.enabled | bool | `false` |  |
| metrics.frontend.enabled | bool | `true` |  |
| metrics.frontend.image.digest | string | `""` |  |
| metrics.frontend.image.repository | string | `"nginx/nginx-prometheus-exporter"` |  |
| metrics.frontend.image.tag | string | `"1.4.2"` |  |
| metrics.frontend.port | int | `9113` |  |
| metrics.frontend.resources | object | `{}` |  |
| metrics.frontend.statusPort | int | `8081` |  |
| metrics.networkPolicy.allowedFrom | list | `[]` |  |
| metrics.scrapeAnnotations | bool | `false` |  |
| metrics.serviceMonitor.annotations | object | `{}` |  |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.honorLabels | bool | `false` |  |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.labels | object | `{}` |  |
| metrics.serviceMonitor.metricRelabelings | list | `[]` |  |
| metrics.serviceMonitor.namespace | string | `""` |  |
| metrics.serviceMonitor.relabelings | list | `[]` |  |
| metrics.serviceMonitor.scrapeTimeout | string | `""` |  |
| nameOverride | string | `""` |  |
| networkPolicy.enabled | bool | `true` |  |
| networkPolicy.extraEgress | list | `[]` |  |
| networkPolicy.frontendAllowedFrom | list | `[]` |  |
| podDisruptionBudget.enabled | bool | `false` |  |
| podDisruptionBudget.maxUnavailable | string | `""` |  |
| podDisruptionBudget.minAvailable | string | `""` |  |
| podSecurityContext.fsGroup | int | `1000` |  |
| podSecurityContext.fsGroupChangePolicy | string | `"OnRootMismatch"` |  |
| podSecurityContext.runAsNonRoot | bool | `false` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| redis.auth.enabled | bool | `false` |  |
| redis.auth.metrics | bool | `false` |  |
| redis.enabled | bool | `true` |  |
| redis.persistence.enabled | bool | `true` |  |
| redis.persistence.size | string | `"2Gi"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automountServiceAccountToken | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| tasks.affinity | object | `{}` |  |
| tasks.nodeSelector | object | `{}` |  |
| tasks.replicas | int | `1` |  |
| tasks.resources | object | `{}` |  |
| tasks.tolerations | list | `[]` |  |
