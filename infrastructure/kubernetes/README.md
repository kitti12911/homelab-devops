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
| keycloak                  | keycloak           | keycloak.lan                                  | identity provider               |
| oauth2-proxy              | oauth2-proxy       | oauth2-proxy.lan                              | forward auth for non-oidc apps  |
| postgresql                | postgresql         | postgres.lan:5432                             | database                        |
| dragonfly                 | dragonfly          | dragonfly.lan:6379                            | redis-compatible cache          |
| nats                      | nats               | nats.lan:4222                                 | messaging                       |
| longhorn                  | longhorn-system    | longhorn.lan                                  | distributed storage             |
| seaweedfs                 | seaweedfs          | seaweedfs.lan, s3.lan                         | object storage                  |
| zot                       | zot                | zot.lan                                       | oci container registry          |
| vault                     | vault              | vault.lan                                     | secret management               |
| kube-prometheus-stack     | monitoring         | grafana.lan, prometheus.lan, alertmanager.lan | monitoring                      |
| loki                      | loki               | loki.lan                                      | log aggregation                 |
| tempo                     | tempo              | tempo.lan                                     | distributed tracing             |
| alloy                     | alloy              | alloy.lan                                     | observability agent             |
| reloader                  | reloader           | -                                             | auto-reload on config changes   |
| system-upgrade-controller | system-upgrade     | -                                             | k3s auto-upgrades               |
| cloudnative-pg            | cnpg-system        | -                                             | postgresql operator             |

## bootstrap order

run these steps in order on a fresh cluster. after argocd is running, it handles everything else.

### 1. flannel (cni)

> K3s v1.34+ no longer initializes its built-in Flannel on startup.
> install flannel manually before argocd is available.

```bash
helm repo add flannel https://flannel-io.github.io/flannel/
helm install flannel --set podCidr="10.42.0.0/16" --namespace kube-flannel --create-namespace flannel/flannel
kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged
```

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

### 3. traefik crd helm adoption fix

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

### 6. argocd

1. add helm repo

    ```bash
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    ```

2. add age key as kubernetes secret

    ```bash
    kubectl create secret generic sops-age \
    --namespace argocd \
    --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
    ```

3. install helm-secrets plugin

    ```bash
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.4/secrets-4.7.4.tgz --verify=false
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.4/secrets-getter-4.7.4.tgz --verify=false
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.4/secrets-post-renderer-4.7.4.tgz --verify=false
    ```

4. install argocd

    ```bash
    helm secrets upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values kubernetes/bootstrap/argocd-values.yml \
    --values kubernetes/bootstrap/argocd-secrets.enc.yml \
    --wait
    ```

5. apply argocd projects

    ```bash
    kubectl apply -f kubernetes/bootstrap/argocd-projects.yml
    ```

6. add private git repo

    ```bash
    argocd repo add git@github.com:kitti12911/homelab-devops.git --ssh-private-key-path ~/.ssh/id_ed25519
    ```

7. rollout restart after updating secrets

    ```bash
    kubectl rollout restart deployment -n argocd
    kubectl rollout restart statefulset -n argocd
    ```

### 7. system-upgrade-controller

install before syncing argocd:

```bash
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml \
  -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
```

### 8. cert-manager

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

### 9. coredns warning suppressed

```bash
kubectl apply -f kubernetes/bootstrap/coredns-warning-suppressed.yml
kubectl rollout restart deployment coredns -n kube-system
```

## app-specific setup

### reloader

annotate workloads to enable auto-reload on secret/configmap changes:

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

### postgresql

set superuser password and encrypt before deploying:

```bash
sops -e -i kubernetes/app/postgresql-manifests/superuser-secret.enc.yml
```

### oauth2-proxy

1. generate cookie secret

    ```bash
    openssl rand -base64 24
    ```

2. fill in the secret and encrypt

    ```bash
    sops -e -i kubernetes/app/oauth2-proxy-manifests/oidc-secret.enc.yml
    ```

3. to protect an app with oauth2-proxy, add a ForwardAuth middleware to the app's manifests:

    ```yaml
    apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
    name: oauth2-proxy-auth
    namespace: <app-namespace>
    spec:
    forwardAuth:
        address: http://oauth2-proxy.oauth2-proxy.svc.cluster.local/
        trustForwardHeader: true
        authResponseHeaders:
        - X-Auth-Request-User
        - X-Auth-Request-Email
    ```

then add an `extensionRef` filter in the app's HTTPRoute:

```yaml
filters:
  - type: ExtensionRef
    extensionRef:
      group: traefik.io
      kind: Middleware
      name: oauth2-proxy-auth
```

sign out: [https://oauth2-proxy.lan/oauth2/sign_out](https://oauth2-proxy.lan/oauth2/sign_out)

### zot (container registry)

install cosign for image signing:

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

enable vault secret engine and store keys:

```bash
vault secrets enable -path=secret kv-v2

vault kv put secret/cosign \
  private-key=@cosign.key \
  public-key=@cosign.pub
```

push cosign public key to zot:

```bash
vault kv get -field=public-key secret/cosign > /tmp/cosign.pub

curl -X POST \
  -u "<username>:<api-key>" \
  --data-binary @/tmp/cosign.pub \
  "https://zot.lan/v2/_zot/ext/cosign"

rm /tmp/cosign.pub
```

sign an image:

> cosign v3+ uses new sigstore bundle format by default which zot does not recognize yet. use `--new-bundle-format=false --use-signing-config=false` for compatibility.

```bash
# get image digest first
docker buildx imagetools inspect zot.lan/<app>:<tag>

# sign with digest
vault kv get -field=private-key secret/cosign > /tmp/cosign.key
cosign sign --new-bundle-format=false --use-signing-config=false \
  --key /tmp/cosign.key zot.lan/<app>@sha256:<digest>
rm /tmp/cosign.key
```

verify an image:

```bash
vault kv get -field=public-key secret/cosign > /tmp/cosign.pub
cosign verify --key /tmp/cosign.pub zot.lan/<app>@sha256:<digest>
rm /tmp/cosign.pub
```

zot does not support logout url, use: [keycloak logout for zot](https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fzot.lan&client_id=zot)

### hashicorp vault

1. initialize vault

    ```bash
    kubectl exec -n vault vault-0 -- vault operator init
    ```

2. unseal vault (3 times with different keys)

    ```bash
    kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key>
    ```

3. install vault cli (macos)

    ```bash
    brew tap hashicorp/tap
    brew install hashicorp/tap/vault
    ```

4. login to vault

    ```bash
    export VAULT_ADDR="https://vault.lan"
    vault login <root-token>
    ```

5. create oidc role

    ```bash
    vault write auth/oidc/role/default \
    bound_audiences="vault" \
    allowed_redirect_uris="https://vault.lan/ui/vault/auth/oidc/oidc/callback" \
    user_claim="preferred_username" \
    groups_claim="groups" \
    token_policies="default"
    ```

6. (optional) map vault roles with keycloak groups

    create policies:

    ```bash
    # admin policy (full access)
    vault policy write vault-admin - <<EOF
    path "*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
    EOF

    # dev policy (read only under secret/data/dev/*)
    vault policy write vault-dev - <<EOF
    path "secret/data/dev/*" {
    capabilities = ["read", "list"]
    }
    path "secret/metadata/dev/*" {
    capabilities = ["list"]
    }
    EOF
    ```

create keycloak groups `vault-admins` and `vault-devs`, then map them:

```bash
ACCESSOR=$(vault auth list -format=json | jq -r '.["oidc/"].accessor')

ADMIN_GROUP_ID=$(vault write -format=json identity/group \
  name="vault-admins" type="external" policies="vault-admin" \
  | jq -r '.data.id')

vault write identity/group-alias \
  name="vault-admins" \
  mount_accessor="$ACCESSOR" \
  canonical_id="$ADMIN_GROUP_ID"

DEV_GROUP_ID=$(vault write -format=json identity/group \
  name="vault-devs" type="external" policies="vault-dev" \
  | jq -r '.data.id')

vault write identity/group-alias \
  name="vault-devs" \
  mount_accessor="$ACCESSOR" \
  canonical_id="$DEV_GROUP_ID"
```

vault does not support logout url, use: [keycloak logout for vault](https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fvault.lan&client_id=vault)

### renovate bot

visit [renovate bot dashboard](https://developer.mend.io) for dependency update management.
