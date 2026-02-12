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

3. enable traefik gateway provider

    ```bash
    kubectl apply -f kubernetes/traefik-helmchartconfig.yml
    ```

4. install longhorn

    ```bash
    helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --values kubernetes/longhorn-values.yml \
    --wait
    ```

5. install reference grant

    ```bash
    kubectl apply -f kubernetes/reference-grant.yml
    ```

### s3 compatible storage (seaweedfs)

1. add seaweedfs and prometheus crds helm repo

    ```bash
    helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    ```

2. install prometheus crds

    ```bash
    helm install prometheus-operator-crds prometheus-community/prometheus-operator-crds
    ```

3. install seaweedfs

    ```bash
    helm upgrade --install seaweedfs seaweedfs/seaweedfs \
    --namespace seaweedfs \
    --create-namespace \
    --values kubernetes/seaweedfs-values.yml \
    --wait
    ```

4. install httproute

    ```bash
    kubectl apply -f kubernetes/seaweedfs-httproute.yml
    ```

5. install fallback nodeport

    ```bash
    kubectl apply -f kubernetes/seaweedfs-nodeport.yml
    ```
