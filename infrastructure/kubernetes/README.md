# kubernetes infrastructure setup

bootstrap and manage kubernetes applications via argocd. all apps are deployed as argocd Applications and synced from this repo.

## requirements

- k3s cluster running (see [ansible README](../../ansible/README.md) for cluster setup)
- kubectl configured to talk to the cluster
- helm installed
- sops + age installed (for secret management)

## deployed applications

| app                       | namespace          | url / endpoint                                | description                     |
|---------------------------|--------------------|-----------------------------------------------|---------------------------------|
| flannel                   | kube-flannel       | -                                             | cni plugin                      |
| cert-manager              | cert-manager       | -                                             | certificate management          |
| trust-manager             | cert-manager       | -                                             | certificate trust distribution  |
| traefik                   | kube-system        | -                                             | ingress / gateway               |
| argocd                    | argocd             | argocd.lan                                    | gitops deployment               |
| keycloak                  | auth               | keycloak.lan                                  | identity provider               |
| keycloak-operator         | auth               | -                                             | keycloak operator               |
| oauth2-proxy              | auth               | oauth2-proxy.lan                              | forward auth for non-oidc apps  |
| postgresql                | database           | postgres.lan:5432                             | database                        |
| dragonfly                 | database           | dragonfly.lan:6379                            | redis-compatible cache          |
| nats                      | database           | nats.lan:4222                                 | messaging                       |
| ~~redpanda~~              | ~~database~~       | ~~redpanda.lan, redpanda.lan:9092~~           | ~~kafka-compatible streaming~~  |
| longhorn                  | longhorn-system    | longhorn.lan                                  | distributed storage             |
| seaweedfs                 | seaweedfs          | seaweedfs.lan, s3.lan                         | object storage                  |
| zot                       | zot                | zot.lan                                       | oci container registry          |
| ~~vault~~                 | ~~vault~~          | ~~vault.lan~~                                 | ~~secret management~~           |
| kube-prometheus-stack     | observability      | grafana.lan, prometheus.lan, alertmanager.lan | monitoring                      |
| loki                      | observability      | loki.lan                                      | log aggregation                 |
| tempo                     | observability      | tempo.lan                                     | distributed tracing             |
| alloy                     | observability      | alloy.lan                                     | observability agent             |
| reloader                  | reloader           | -                                             | auto-reload on config changes   |
| system-upgrade-controller | system-upgrade     | -                                             | k3s auto-upgrades               |
| cloudnative-pg            | cnpg-system        | -                                             | postgresql operator             |

## app sync order

sync apps in this order after argocd is running. each wave depends on the previous being healthy.

| wave | apps                                                                       | reason                                                                 |
|------|----------------------------------------------------------------------------|------------------------------------------------------------------------|
| 1    | cert-manager, cloudnative-pg, keycloak-operator, longhorn                  | operators and storage - no dependencies                                |
| 2    | trust-manager, postgresql, dragonfly, nats, seaweedfs                      | trust-manager needs cert-manager; dbs need cnpg + longhorn             |
| 3    | keycloak, kube-prometheus-stack                                            | keycloak needs keycloak-operator + postgresql                          |
| 4    | oauth2-proxy, zot, loki, tempo, alloy, reloader, system-upgrade-controller | oauth2-proxy + zot need keycloak; observability stack needs prometheus |

## bootstrap order

run these steps in order on a fresh cluster. after argocd is running, it handles everything else.

### 2. gateway api

```bash
kubectl apply -f kubernetes/bootstrap/gateway.yml
```

enable traefik gateway provider:

```bash
kubectl apply -f kubernetes/bootstrap/traefik-helmchartconfig.yml
```

apply security headers middleware:

```bash
kubectl apply -f kubernetes/bootstrap/traefik-middleware.yml
```

### 4. prometheus crds

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus-operator-crds prometheus-community/prometheus-operator-crds
```

### 5. sops/age

1. generate age key (don't push to git!)

    ```bash
    age-keygen -o age.key
    mkdir -p ~/.config/sops/age
    cat age.key >> ~/.config/sops/age/keys.txt
    rm age.key
    chmod 600 ~/.config/sops/age/keys.txt
    echo 'export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt' >> ~/.zshrc
    source ~/.zshrc
    ```

2. encrypt a secret

    ```bash
    sops -e -i <path>
    ```

3. decrypt a secret

    ```bash
    sops -d -i <path>
    ```

4. install helm-secrets plugin

    ```bash
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.6/secrets-4.7.6.tgz --verify=false
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.6/secrets-getter-4.7.6.tgz --verify=false
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.6/secrets-post-renderer-4.7.6.tgz --verify=false
    ```

### 6. argocd

1. install argocd

    ```bash
    helm secrets upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --values kubernetes/bootstrap/argocd-values.yml \
    --values kubernetes/bootstrap/argocd-secrets.enc.yml \
    --wait
    ```

2. apply argocd projects

    ```bash
    kubectl apply -f kubernetes/bootstrap/argocd-projects.yml
    ```

3. login argocd with nodeport

    ```bash
    argocd login 192.168.88.202:30800 --username admin --password <password>
    ```

4. add private git repo

    ```bash
    argocd repo add git@github.com:kitti12911/homelab-devops.git --ssh-private-key-path ~/.ssh/id_ed25519
    ```

5. apply app-in-app

    ```bash
    kubectl apply -f kubernetes/bootstrap/apps.yml
    ```

### 7. cert-manager

apply wildcard certificate:

```bash
kubectl apply -f kubernetes/bootstrap/lan-certificate.yml
```

extract CA certificate and add to system truststore:

```bash
kubectl get secret homelab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt

# macos
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt
rm homelab-ca.crt
```
