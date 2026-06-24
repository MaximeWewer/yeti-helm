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

## Security

- Hardened `containerSecurityContext`: `allowPrivilegeEscalation: false`, `drop: [ALL]`, `privileged: false` (+ `seccompProfile: RuntimeDefault` at the pod level).
- `automountServiceAccountToken: false`.
- **`podSecurityContext.runAsNonRoot` defaults to `false`**: the `yetiplatform/*` images have no verified non-root uid. After testing (check the image uid), switch to `true` + a suitable `runAsUser`, and `containerSecurityContext.readOnlyRootFilesystem: true` if the app supports it.
- NetworkPolicy: frontend ingress restricted (`networkPolicy.frontendAllowedFrom`), intra-app traffic limited (api 8000, bloomcheck 8100). **Egress**: DNS + intra-namespace. Yeti fetches **external feeds** (tasks) → add outbound egress (443) via `networkPolicy.extraEgress`.
- Secrets never in cleartext in the values: use `config.existingSecret` (ESO/Vault) in production.

## Advanced configuration

Yeti maps `yeti.conf` onto `YETI_<SECTION>_<KEY>` environment variables. The chart exposes the structured sections via `config.*` and delegates the rest (feed API keys, MISP, creds) to `extraEnvFrom`.

| yeti.conf section | Exposed via | Notes |
|-------------------|-------------|-------|
| `[rbac]` | `config.rbac.{enabled,defaultGlobalRole,defaultAcls}` | RBAC disabled upstream by default → **`enabled: true` recommended** for shared deployments |
| `[events]` | `config.events.{memoryLimit,keepRatio,consumersConcurrency}` | Events worker tuning |
| `[agents]` | `agents.enabled` | **`false` by default**. When `true`: deploys the agents StatefulSet+Service **and** wires `YETI_AGENTS_ENABLED/HTTP_ROOT/WEBSOCKET_ROOT` |
| `[proxy]` | `config.proxy.{http,https}` | Outbound proxy for feeds (`socks5://…` / `http://…`) |
| `[system] export_path` | `config.system.exportPath` | Local (PVC) **or** `s3://bucket/prefix` (`AWS_*` creds via `extraEnvFrom`, image with the `s3` extra) |
| `[timesketch]` | `config.timesketch.{enabled,endpoint,existingSecret}` | Optional integration (Timesketch = backlog) |
| `[misp]`, `[vt]`, `[otx]`, `[shodan]`, `[censys]`, `[abuseIPDB]`, `[dnsdb]`, `[github]`, `[datadog]`, … | **`extraEnvFrom`** | API keys / creds from a Secret. Yeti reads `YETI_<SECTION>_<KEY>` |
| `[auth]`, `[arangodb]`, `[redis]`, `[bloom]` | managed by the chart | secret/hosts/bloom already wired |

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

## Notes

- `beats` (Celery beat) is a singleton — do not scale it.
- `exports` must be **ReadWriteMany** (NFS/EFS) on multi-node clusters (shared by api/tasks/events).
- Yeti does not support Redis auth → `redis.auth.enabled=false` is required.
- ArangoDB root password = the `password` key of the secret (used both by the operator at bootstrap and by Yeti via `YETI_ARANGODB_PASSWORD`).

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| oci://registry-1.docker.io/cloudpirates | redis | 0.30.* |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| agents.affinity | object | `{}` |  |
| agents.dbPath | string | `"/data/sessions.db"` |  |
| agents.enabled | bool | `false` |  |
| agents.image.digest | string | `""` |  |
| agents.image.repository | string | `"yetiplatform/yeti-agents"` |  |
| agents.image.tag | string | `"2.5.0"` |  |
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
| api.image.tag | string | `"2.5.0"` |  |
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
| config.createUser | bool | `true` |  |
| config.events.consumersConcurrency | int | `2` |  |
| config.events.keepRatio | float | `0.9` |  |
| config.events.memoryLimit | int | `64` |  |
| config.existingSecret | string | `""` |  |
| config.imagePullPolicy | string | `"IfNotPresent"` |  |
| config.initDependencyCheck.image | string | `"busybox:1.36"` |  |
| config.oidc.allowedExtraAudiences | string | `""` |  |
| config.oidc.discoveryUrl | string | `"https://accounts.google.com/.well-known/openid-configuration"` |  |
| config.oidc.enabled | bool | `false` |  |
| config.oidc.existingSecret | string | `""` |  |
| config.proxy.http | string | `""` |  |
| config.proxy.https | string | `""` |  |
| config.rbac.defaultAcls | string | `"All users"` |  |
| config.rbac.defaultGlobalRole | string | `"writer"` |  |
| config.rbac.enabled | bool | `false` |  |
| config.system.exportPath | string | `"/opt/yeti/exports"` |  |
| config.timesketch.enabled | bool | `false` |  |
| config.timesketch.endpoint | string | `""` |  |
| config.timesketch.existingSecret | string | `""` |  |
| config.timesketch.passwordKey | string | `"timesketch-password"` |  |
| config.timesketch.usernameKey | string | `"timesketch-user"` |  |
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
| frontend.image.tag | string | `"2.5.0"` |  |
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
