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

### argocd

1. add argocd helm repo

    ```bash
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    ```

2. install argocd

    ```bash
    helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values kubernetes/bootstrap/argocd-values.yml \
    --wait
    ```

### sops/ages

### cert-manager

### reloader

### postgresql

### redis compatible database (dragonfly)

### keycloak

### hashicorp vault

### grafana prometheus stack

### grafana loki

### grafana tempo
