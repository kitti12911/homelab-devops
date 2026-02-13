# kubernetes infrastructure setup

run helm charts or manifests for kubernetes infrastructure.

## setup script

### gateway api

1. install gateway api

    ```bash
    kubectl apply -f kubernetes/bootstrap/gateway.yml
    ```

2. enable traefik gateway provider

    ```bash
    kubectl apply -f kubernetes/bootstrap/traefik-helmchartconfig.yml
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

3. install argocd

    ```bash
    helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values kubernetes/bootstrap/argocd-values.yml \
    --wait
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

### redis compatible database (dragonfly)

### nats

### keycloak

### zot

### hashicorp vault

### grafana prometheus stack

### grafana loki

### grafana tempo
