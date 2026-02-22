# infrastructure

kubernetes infrastructure for the homelab. all apps are managed by argocd and deployed from this repo.

for full bootstrap and setup instructions, see [kubernetes/README.md](kubernetes/README.md).

## static dns list

### http services

| dns                  | description                  |
|----------------------|------------------------------|
| argocd.lan           | gitops deployment            |
| keycloak.lan         | identity provider            |
| oauth2-proxy.lan     | forward auth proxy           |
| vault.lan            | secret management            |
| longhorn.lan         | distributed storage          |
| zot.lan              | container registry           |
| seaweedfs.lan        | object storage (filer)       |
| seaweedfs-admin.lan  | object storage (admin)       |
| s3.lan               | s3-compatible endpoint       |
| grafana.lan          | dashboards and visualization |
| prometheus.lan       | metrics                      |
| alertmanager.lan     | alert management             |
| loki.lan             | log aggregation              |
| tempo.lan            | distributed tracing          |
| alloy.lan            | observability agent          |

### tcp services

| dns              | port  | description              |
|------------------|-------|--------------------------|
| postgres.lan     | 5432  | postgresql database      |
| nats.lan         | 4222  | nats messaging           |
| dragonfly.lan    | 6379  | redis-compatible cache   |
