# Yeti Helm Chart

Helm chart for [Yeti](https://github.com/yeti-platform/yeti) on Kubernetes.

## Features

- frontend, API, Celery workers (tasks / events / beat), optional agents + bloomcheck
- ArangoDB via the [kube-arangodb](https://github.com/arangodb/kube-arangodb) operator (`ArangoDeployment`)
- Redis via the [CloudPirates](https://github.com/CloudPirates-io/helm-charts) chart (Celery broker)
- NetworkPolicies, PodDisruptionBudget, hardened securityContext, generate-once secrets
- `extraEnvFrom` for feed API keys / MISP / S3 (`YETI_<SECTION>_<KEY>`)
- Automated weekly version updates tracking upstream Yeti releases

## Prerequisites

- A Kubernetes cluster, Helm **3+**.
- **kube-arangodb operator** installed cluster-wide (this chart ships only the `ArangoDeployment` CR):
  ```sh
  helm install kube-arangodb \
    https://github.com/arangodb/kube-arangodb/releases/download/<ver>/kube-arangodb-<ver>.tgz \
    --set "operator.features.deployment=true"
  ```
- Optional: a `ReadWriteMany` StorageClass (NFS/EFS) for the shared `exports` volume on multi-node clusters.

## Installation

### Helm (OCI)

```bash
helm install yeti oci://ghcr.io/maximewewer/charts/yeti \
  --namespace cti --create-namespace
```

### From source

```bash
git clone https://github.com/MaximeWewer/yeti-helm.git
cd yeti-helm
helm dependency build chart/
helm install yeti chart/ --namespace cti --create-namespace
```

### Argo CD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: yeti
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ghcr.io/maximewewer/charts
    chart: yeti
    targetRevision: "<chart-version>"   # pin a published version
  destination:
    server: https://kubernetes.default.svc
    namespace: cti
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Secrets are generated automatically when `config.existingSecret` is not provided. Initial admin password:

```bash
kubectl get secret -n cti yeti-secret -o jsonpath='{.data.yeti-user}' | base64 -d
```

## Configuration

See the full list of configurable values in [`chart/README.md`](chart/README.md).

## License

This chart is distributed under the [Apache License 2.0](LICENSE). Yeti itself is licensed by the Yeti Platform project.
