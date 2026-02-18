# kubernetes infrastructure setup

run helm charts or manifests for kubernetes infrastructure.

## setup script

### flannel (cni)

> **Note:** K3s v1.34+ no longer initializes its built-in Flannel on startup.
> Flannel must be deployed separately before any pods can start.
> This is managed by ArgoCD via the official Flannel Helm chart, but on
> initial cluster setup you need to install it manually first (before ArgoCD is installed).

1. install flannel

    ```bash
    helm repo add flannel https://flannel-io.github.io/flannel/
    helm install flannel --set podCidr="10.42.0.0/16" --namespace kube-flannel --create-namespace flannel/flannel
    kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged
    ```

### gateway api

1. install gateway api

    ```bash
    kubectl apply -f kubernetes/bootstrap/gateway.yml
    ```

2. enable traefik gateway provider

    ```bash
    kubectl apply -f kubernetes/bootstrap/traefik-helmchartconfig.yml
    ```

3. apply security headers middleware

    ```bash
    kubectl apply -f kubernetes/bootstrap/traefik-middleware.yml
    ```

### traefik crd helm adoption fix

if `helm-install-traefik-crd` job is stuck in `CrashLoopBackOff` because Gateway API CRDs
already exist without Helm ownership metadata, label them so Helm can adopt them:

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

### prometheus crds

1. add prometheus crds helm repo

    ```bash
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    ```

2. install prometheus crds

    ```bash
    helm install prometheus-operator-crds prometheus-community/prometheus-operator-crds
    ```

### sops/age

1. install age tool

    ```bash
    go install filippo.io/age/cmd/...@latest
    ```

2. install sops tool

    ```bash
    curl -LO https://github.com/getsops/sops/releases/download/v3.11.0/sops-v3.11.0.darwin.arm64
    sudo mv sops-v3.11.0.darwin.arm64 /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
    ```

3. generate age key (don't push to git!)

    ```bash
    age-keygen -o age.key
    mkdir -p ~/.config/sops/age
    cat age.key >> ~/.config/sops/age/keys.txt
    rm age.key
    chmod 600 ~/.config/sops/age/keys.txt
    echo 'export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt' >> ~/.zshrc
    source ~/.zshrc
    ```

4. encrypt secret

    ```bash
    sops -e -i <path>
    ```

5. decrypt secret

    ```bash
    sops -d -i <path>
    ```

### argocd

1. add argocd helm repo

    ```bash
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    ```

2. add age key to argocd secret

    ```bash
    kubectl create secret generic sops-age \
    --namespace argocd \
    --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
    ```

3. apply argocd projects

    ```bash
    kubectl apply -f kubernetes/bootstrap/argocd-projects.yml
    ```

4. add private git repo (leave project empty so all projects can access it)

    ```bash
    argocd repo add git@github.com:kitti12911/homelab-devops.git --ssh-private-key-path ~/.ssh/id_ed25519
    ```

5. install helm secrets plugin

    ```bash
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.4/secrets-4.7.4.tgz --verify=false
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.4/secrets-getter-4.7.4.tgz --verify=false
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v4.7.4/secrets-post-renderer-4.7.4.tgz --verify=false
    ```

6. install argocd

    ```bash
    helm secrets upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values kubernetes/bootstrap/argocd-values.yml \
    --values kubernetes/bootstrap/argocd-secrets.enc.yml \
    --wait
    ```

7. rollout restart after update secret

    ```bash
    kubectl rollout restart deployment -n argocd
    kubectl rollout restart statefulset -n argocd
    ```

8. apply argocd project

    ```bash
    kubectl apply -f kubernetes/bootstrap/argocd-projects.yml
    ```

### system-upgrade-controller

1. install system-upgrade-controller before sync argocd

    ```bash
    kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml \
      -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
    ```

### reloader

- annotate workloads to enable auto-reload on secret/configmap changes

    ```yaml
    metadata:
      annotations:
        reloader.stakater.com/auto: "true"
    ```

### postgresql

1. set superuser password and encrypt before deploying

    ```bash
    sops -e -i kubernetes/app/postgresql-manifests/superuser-secret.enc.yml
    ```

### cert-manager

1. apply wildcard certificate

    ```bash
    kubectl apply -f kubernetes/bootstrap/lan-certificate.yml
    ```

2. extract CA certificate and add to system truststore

    ```bash
    kubectl get secret homelab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt

    # for macos
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt
    rm homelab-ca.crt
    ```

### zot

- zot do not support logout url so please use following url for logout after zot logout

    [https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fzot.lan&client_id=zot](https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fzot.lan&client_id=zot)

- sign image with cosign

1. install cosign

    ```bash
    brew install cosign
    ```

2. login cosign with zot.lan (use api key as password)

    ```bash
    cosign login zot.lan --username <username> --password <api-key>
    ```

3. generate key pair

    ```bash
    cosign generate-key-pair
    ```

4. enable vault secret engine

    ```bash
    vault secrets enable -path=secret kv-v2
    ```

5. store key and pub to vault

    ```bash
    vault kv put secret/cosign \
    private-key=@cosign.key \
    public-key=@cosign.pub
    ```

6. push cosign public key from vault to zot

    ```bash
    vault kv get -field=public-key secret/cosign > /tmp/cosign.pub

    curl -X POST \
    -u "<username>:<api-key>" \
    --data-binary @/tmp/cosign.pub \
    "https://zot.lan/v2/_zot/ext/cosign"

    rm /tmp/cosign.pub
    ```

7. get image digest (use the manifest list digest for multi-arch images)

    ```bash
    docker buildx imagetools inspect zot.lan/<app>:<tag>
    ```

8. sign image with digest from vault

    > **Note:** cosign v3+ uses new sigstore bundle format by default which zot
    > does not recognize yet. use `--new-bundle-format=false --use-signing-config=false`
    > for compatibility.

    ```bash
    vault kv get -field=private-key secret/cosign > /tmp/cosign.key
    cosign sign --new-bundle-format=false --use-signing-config=false \
    --key /tmp/cosign.key zot.lan/<app>@sha256:<digest>
    rm /tmp/cosign.key
    ```

9. verify image

    ```bash
    vault kv get -field=public-key secret/cosign > /tmp/cosign.pub
    cosign verify --key /tmp/cosign.pub zot.lan/<app>@sha256:<digest>
    rm /tmp/cosign.pub
    ```

### hashicorp vault

1. initialize vault

    ```bash
    kubectl exec -n vault vault-0 -- vault operator init
    ```

2. unseal vault 3 times

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

5. create role with

    ```bash
    vault write auth/oidc/role/default \
    bound_audiences="vault" \
    allowed_redirect_uris="https://vault.lan/ui/vault/auth/oidc/oidc/callback" \
    user_claim="preferred_username" \
    groups_claim="groups" \
    token_policies="default"
    ```

6. like zot, vault don't support logout url so please use following url for logout after vault logout

    [https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fvault.lan&client_id=vault](https://keycloak.lan/realms/homelab/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fvault.lan&client_id=vault)

7. (optional) map vault role with keycloak group

    - create policies

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

    - create keycloak groups `vault-admins` and `vault-devs`

    - map keycloak groups to vault policies

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

### renovate bot

> please visit [renovate bot](https://developer.mend.io) for dashboard and documentation.

### coredns warning suppressed

1. apply coredns warning suppressed configmap

    ```bash
    kubectl apply -f kubernetes/bootstrap/coredns-warning-suppressed.yml
    ```

2. restart coredns pod

    ```bash
    kubectl rollout restart deployment coredns -n kube-system
    ```
