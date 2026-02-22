# homelab-devops

infrastructure and configuration for the homelab. manages kubernetes cluster setup, application deployment, and node provisioning.

## overview

- **ansible/** - playbooks for provisioning nodes (raspberry pi, proxy, k3s cluster)
- **infrastructure/** - kubernetes manifests, helm charts, and argocd applications
- **scripts/** - utility scripts (docker compose for local db, etc.)

## requirements

- [ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) for node provisioning
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster management
- [helm](https://helm.sh/docs/intro/install/) for chart management
- [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) for secret encryption
- [argocd cli](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional, for repo management)

## install tools

### kubectl

```bash
# macos
brew install kubectl

# linux
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

### helm

```bash
# macos
brew install helm

# linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
```

### sops

```bash
curl -LO https://github.com/getsops/sops/releases/download/v3.11.0/sops-v3.11.0.darwin.arm64
sudo mv sops-v3.11.0.darwin.arm64 /usr/local/bin/sops
sudo chmod +x /usr/local/bin/sops
```

### age

```bash
go install filippo.io/age/cmd/...@latest
```

## project structure

```bash
homelab-devops/
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   └── playbooks/
│       ├── infrastructure/     # node setup playbooks
│       ├── kubernetes/         # k3s cluster playbooks
│       └── utility/            # reboot, poweroff, etc.
├── infrastructure/
│   └── kubernetes/
│       ├── app/                # argocd applications + manifests
│       └── bootstrap/          # initial cluster setup resources
├── scripts/
│   └── compose/
│       └── db.compose.yml      # local database for development
└── .sops.yaml                  # sops encryption rules
```

## getting started

1. set up ansible for node provisioning - see [ansible/README.md](ansible/README.md)
2. bootstrap the kubernetes cluster - see [infrastructure/kubernetes/README.md](infrastructure/kubernetes/README.md)
3. argocd handles the rest (syncs apps from this repo automatically)

## secret management

secrets are encrypted with sops + age. encrypted files end with `.enc.yml`.

encrypt a file:

```bash
sops -e -i <path>
```

decrypt a file:

```bash
sops -d -i <path>
```

see the kubernetes README for full sops/age setup instructions.
