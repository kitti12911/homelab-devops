# kubernetes infrastructure setup

run helm charts or manifests for kubernetes infrastructure.

## setup script

### longhorn

1. add longhorn helm repo

    ```bash
    helm repo add longhorn https://charts.longhorn.io
    helm repo update
    ```

2. install gateway api

    ```bash
    kubectl apply -f kubernetes/gateway.yml
    ```

3. install longhorn

    ```bash
    helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --values kubernetes/longhorn-values.yml \
    --wait
    ```
