# ansible

ansible playbooks for provisioning homelab nodes and setting up k3s cluster.

## requirements

- ansible installed
- ssh access to target node(s)

## install ansible

- macos:

    ```bash
    brew install ansible
    ```

- linux (pip):

    ```bash
    pip install ansible
    ```

## setup

### ssh access

1. generate ssh key for ansible

    ```bash
    ssh-keygen -t ed25519 -C "ansible"
    ```

2. copy public key to node(s)

    ```bash
    ssh-copy-id -i ~/.ssh/id_ed25519_ansible.pub <user>@<host>
    ```

3. test connection

    ```bash
    ssh -i ~/.ssh/id_ed25519_ansible <user>@<host>
    ```

### vault password

ansible vault is used to encrypt sensitive variables (like passwords, tokens).

create vault password file:

```bash
echo "your-vault-password" > .vault_password
chmod 600 .vault_password
```

> `.vault_password` is gitignored. don't commit it.

create encrypted vault file:

```bash
ansible-vault create inventory/group_vars/all/vault.yml
```

edit:

```bash
ansible-vault edit inventory/group_vars/all/vault.yml
```

encrypt / decrypt manually:

```bash
ansible-vault encrypt inventory/group_vars/all/vault.yml
ansible-vault decrypt inventory/group_vars/all/vault.yml
```

## inventory

inventory is defined in `inventory/hosts.yml`. the `ansible.cfg` already points to it so you don't need to pass `-i` every time.

### host groups

| group          | hosts                        | description            |
|----------------|------------------------------|------------------------|
| master         | alpha-actual                 | k3s master node        |
| computer       | bravo, charlie, delta        | k3s worker nodes       |
| object_storage | kilo                         | object storage node    |
| database       | november                     | database node          |
| nas            | sierra                       | nas / file storage     |
| builder        | romeo                        | build server           |
| proxy          | hotel                        | reverse proxy          |

check current inventory:

```bash
ansible-inventory --graph
```

test connection to all hosts:

```bash
ansible all -m ping
```

## playbooks

### infrastructure

| playbook                    | description                        |
|-----------------------------|------------------------------------|
| `setup-raspberry-pi-os.yml` | initial raspberry pi os setup      |
| `setup-cloudflared.yml`     | setup cloudflare tunnel            |
| `setup-proxy.yml`           | setup envoy proxy node             |
| `add-public-key.yml`        | add ssh public keys to nodes       |
| `update-dependencies.yml`   | update system packages             |

### kubernetes

| playbook                    | description                        |
|-----------------------------|------------------------------------|
| `initial-setup-node.yml`    | prepare node for k3s               |
| `setup-master.yml`          | install k3s master                 |
| `setup-worker.yml`          | install k3s worker and join cluster|

### utility

| playbook        | description           |
|-----------------|-----------------------|
| `reboot.yml`    | reboot hosts          |
| `poweroff.yml`  | power off hosts       |

## how to run

run a playbook on all hosts in its target group:

```bash
ansible-playbook playbooks/infrastructure/setup-raspberry-pi-os.yml
```

run on a specific host:

```bash
ansible-playbook playbooks/infrastructure/setup-raspberry-pi-os.yml --limit november
```

run a specific task by tag:

```bash
ansible-playbook playbooks/infrastructure/setup-raspberry-pi-os.yml --limit november -t "Get root filesystem device"
```

## config

`ansible.cfg` is already set up with:

- default inventory: `inventory/`
- ssh key: `~/.ssh/id_ed25519_ansible`
- vault password file: `.vault_password`
- ssh pipelining enabled for faster execution
