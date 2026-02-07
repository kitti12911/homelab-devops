# ansible

ansible playbooks and roles for homelab infra

## prerequisites

- ansible installed
- ssh access to node(s)

## setup

### set ssh access for ansible

1. generate ssh key for ansible

    ```bash
    ssh-keygen -t ed25519 -C "ansible"
    ```

2. copy public key to node(s)

    ```bash
    ssh-copy-id -i <ssh location> <user>@<host>
    ```

3. test connection with specific private key

    ```bash
    ssh -i <ssh location> <user>@<host>
    ```

    or ping with

    ```bash
    ansible all --key-file <ssh location> -i inventory/<inventory file> -m ping
    ```

    or with `ansible.cfg` set

    ```bash
    ansible all -i inventory/<inventory file> -m ping
    ```

    or more beautiful ad hoc output

    ```bash
    ANSIBLE_CALLBACK_RESULT_FORMAT=yaml ansible all -m ping
    ```

### inventory file

- see `inventory/hosts.yml` for the inventory file.
- see current structure with

    ```bash
    ansible-inventory --graph
    ```

- ping with less commands

    ```bash
    ansible all -m ping
    ```

### vault password management

- run command to create vault password

    ```bash
    ansible-vault create inventory/group_vars/all/vault.yml
    ```

- edit vault password

    ```bash
    ansible-vault edit inventory/group_vars/all/vault.yml
    ```

- decrypt vault password

    ```bash
    ansible-vault decrypt inventory/group_vars/all/vault.yml
    ```

- encrypt vault password

    ```bash
    ansible-vault encrypt inventory/group_vars/all/vault.yml
    ```

### install ansible collections

### run playbook

- see `playbooks/setup-raspberry-pi-os.yml` for an example

    ```bash
    ansible-playbook -i inventory/hosts.yml playbooks/setup-raspberry-pi-os.yml
    ```

- run with specific host(s)

    ```bash
    ansible-playbook -i inventory/hosts.yml playbooks/setup-raspberry-pi-os.yml -l november
    ```

- run with specific host(s) and specific task

    ```bash
    ansible-playbook -i inventory/hosts.yml playbooks/setup-raspberry-pi-os.yml -l november -t "Get root filesystem device"
    ```

- run with limit

    ```bash
    ansible-playbook playbooks/setup-raspberry-pi-os.yml --limit "november"
    ```
