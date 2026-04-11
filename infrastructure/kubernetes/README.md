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

### 1. gateway api

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

### 2. prometheus crds

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus-operator-crds prometheus-community/prometheus-operator-crds
```

### 3. sops/age

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

### 4. argocd

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
    kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
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

6. delete initial admin secret after keycloak oidc is working

    ```bash
    argocd admin initial-password -n argocd
    kubectl delete secret argocd-initial-admin-secret -n argocd
    ```

### 5. cert-manager

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

### 6. keycloak configuration

after keycloak is running, set up the realm and clients so all apps can authenticate.

get the initial admin credentials (generated by the operator):

```bash
kubectl get secret keycloak-initial-admin -n auth -o jsonpath='{.data.username}' | base64 -d
kubectl get secret keycloak-initial-admin -n auth -o jsonpath='{.data.password}' | base64 -d
```

#### realm

create realm `homelab` at [keycloak.lan](https://keycloak.lan).

#### groups

create these groups (used for role mapping across apps):

| group             | used by                         |
|-------------------|---------------------------------|
| `argocd-admins`   | argocd — admin role             |
| `argocd-viewers`  | argocd — readonly role          |
| `grafana-admins`  | grafana — Admin role            |
| `grafana-editors` | grafana — Editor role           |
| `zot-admins`      | zot — admin role                |

#### client scope: groups

add a `groups` client scope at the realm level so all clients can receive group memberships in tokens:

1. **client scopes** → create scope named `groups`, type `optional`
2. add mapper: type `Group Membership`, token claim name `groups`, turn off **full group path**
3. add this scope to every client below

#### clients

create these clients (capability config: `client authentication` on, `standard flow` on):

##### argocd

| field                          | value                                          |
|--------------------------------|------------------------------------------------|
| root url                       | `https://argocd.lan`                           |
| home url                       | `https://argocd.lan`                           |
| valid redirect uris            | `https://argocd.lan/auth/callback`             |
|                                | `http://192.168.88.202:30800/auth/callback`    |
| valid post logout redirect uris| `https://argocd.lan`                           |
| web origins                    | `https://argocd.lan`                           |

##### grafana

| field                          | value                                     |
|--------------------------------|-------------------------------------------|
| root url                       | `https://grafana.lan`                     |
| home url                       | `https://grafana.lan`                     |
| valid redirect uris            | `https://grafana.lan/login/generic_oauth` |
| valid post logout redirect uris| `https://grafana.lan`                     |
| web origins                    | `https://grafana.lan`                     |

##### zot

| field                          | value                               |
|--------------------------------|-------------------------------------|
| root url                       | `https://zot.lan`                   |
| home url                       | `https://zot.lan`                   |
| valid redirect uris            | `https://zot.lan/zot/auth/callback` |
| valid post logout redirect uris| `https://zot.lan`                   |
| web origins                    | `https://zot.lan`                   |

##### oauth2-proxy

| field                          | value                                      |
|--------------------------------|--------------------------------------------|
| root url                       | `https://oauth2-proxy.lan`                 |
| home url                       | `https://oauth2-proxy.lan`                 |
| valid redirect uris            | `https://oauth2-proxy.lan/oauth2/callback` |
| valid post logout redirect uris| `https://oauth2-proxy.lan`                 |
| web origins                    | `https://oauth2-proxy.lan`                 |

for each client:

- copy the client secret into the corresponding encrypted secret in this repo
- add the `groups` scope under **client scopes**

#### users

create at least one user and assign to the appropriate groups. the user must verify their email (or disable email verification in realm settings) before login works.

after your own admin user is working, delete the temporary bootstrap account:

1. in keycloak admin ui: **users** → delete the `temp-admin` user (or whatever the initial admin username was)
2. delete the operator-generated secret:

    ```bash
    kubectl delete secret keycloak-initial-admin -n auth
    ```

### 7. oauth2-proxy

1. generate cookie secret

    ```bash
    openssl rand -base64 24
    ```

2. fill in the secret and encrypt

### 8. system-upgrade-controller

install before syncing argocd:

```bash
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml \
  -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
```

## fixes

### traefik crd helm adoption fix

if `helm-install-traefik-crd` job is stuck in CrashLoopBackOff because Gateway API CRDs already exist without Helm ownership metadata:

```bash
for crd in $(kubectl get crd -o name | grep gateway.networking.k8s.io); do
  kubectl label "$crd" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate "$crd" meta.helm.sh/release-name=traefik-crd --overwrite
  kubectl annotate "$crd" meta.helm.sh/release-namespace=kube-system --overwrite
done
```

then delete the stuck job so k3s recreates it:

```bash
kubectl delete job helm-install-traefik-crd -n kube-system
```

### coredns warning suppressed

if coredns logs are spamming warnings about the kubernetes plugin deprecation:

```bash
kubectl apply -f kubernetes/bootstrap/coredns-warning-suppressed.yml
kubectl rollout restart deployment coredns -n kube-system
```

## reloader

### enabling auto-reload

annotate workloads to auto-restart when their referenced secrets or configmaps change:

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

### watching specific resources

to only reload when specific labeled resources change:

```yaml
metadata:
  annotations:
    reloader.stakater.com/search: "true"
```

then label the secret or configmap:

```yaml
metadata:
  labels:
    reloader.stakater.com/match: "true"
```

to watch a specific secret or configmap by name:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "my-secret"
    configmap.reloader.stakater.com/reload: "my-configmap"
```

multiple resources can be comma-separated:

```yaml
secret.reloader.stakater.com/reload: "secret1,secret2"
```

### verifying reloader

check reloader logs to confirm it detected a change and triggered a rollout:

```bash
kubectl logs -n reloader -l app.kubernetes.io/name=reloader --tail=50
```

check if a deployment was recently rolled:

```bash
kubectl rollout history deployment/<name> -n <namespace>
```

## oauth2-proxy usage

### protecting an app with oauth2-proxy

1. create a `Middleware` resource in the app's namespace:

    ```yaml
    apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: oauth2-proxy-auth
      namespace: <app-namespace>
    spec:
      forwardAuth:
        address: http://oauth2-proxy.auth.svc.cluster.local/
        trustForwardHeader: true
        authResponseHeaders:
          - X-Auth-Request-User
          - X-Auth-Request-Email
    ```

2. add an `extensionRef` filter to the app's HTTPRoute:

    ```yaml
    filters:
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: oauth2-proxy-auth
    ```

3. create the keycloak client for oauth2-proxy if not already done (see [keycloak configuration](#6-keycloak-configuration))

### sign out

clear the oauth2-proxy session: [https://oauth2-proxy.lan/oauth2/sign_out](https://oauth2-proxy.lan/oauth2/sign_out)

full logout (also signs out of keycloak):

```text
https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Foauth2-proxy.lan&client_id=oauth2-proxy
```

### troubleshooting

```bash
kubectl logs -n auth -l app.kubernetes.io/name=oauth2-proxy --tail=50
```

- **redirect loop**: verify `valid redirect uris` in the keycloak client match the actual callback URL exactly.
- **403 after login**: user not in the required keycloak group, or `groups` client scope not assigned to the client.
- **cookie too large**: too many groups/claims in the token. reduce claims or switch to a redis session store.

## zot image signing

### setup

install cosign:

```bash
brew install cosign
```

login to zot (use api key as password):

```bash
cosign login zot.lan --username <username> --password <api-key>
```

generate key pair:

```bash
cosign generate-key-pair
```

store keys in the repo and encrypt the private key:

```bash
mkdir -p kubernetes/secrets/cosign
mv cosign.key kubernetes/secrets/cosign/cosign.key
mv cosign.pub kubernetes/secrets/cosign/cosign.pub
```

push cosign public key to zot:

```bash
curl -X POST \
  -u "<username>:<api-key>" \
  --data-binary @kubernetes/secrets/cosign/cosign.pub \
  "https://zot.lan/v2/_zot/ext/cosign"
```

### building and pushing an image

login to zot:

```bash
docker login zot.lan --username <username> --password <api-key>
```

build and push:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t zot.lan/<app>:<tag> --push .
```

single platform:

```bash
docker build -t zot.lan/<app>:<tag> .
docker push zot.lan/<app>:<tag>
```

### signing an image

> cosign v3+ uses new sigstore bundle format by default which zot does not recognize yet. use `--new-bundle-format=false --use-signing-config=false` for compatibility.

```bash
docker buildx imagetools inspect zot.lan/<app>:<tag>

cosign sign --new-bundle-format=false --use-signing-config=false \
  --key kubernetes/secrets/cosign/cosign.key zot.lan/<app>@sha256:<digest>
```

### verifying an image

```bash
cosign verify --key kubernetes/secrets/cosign/cosign.pub zot.lan/<app>@sha256:<digest>
```

zot does not support logout url, use: [keycloak logout for zot](https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fzot.lan&client_id=zot)
