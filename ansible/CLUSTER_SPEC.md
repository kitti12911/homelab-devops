# Cluster Spec

This document captures the homelab node layout and hardware spec separately from the Ansible usage notes in `README.md`.

Keep this file in sync with `inventory/hosts.yml` and `inventory/host_vars/*/vars.yml`.

## Network

- Default Ansible user: `kitti`
- Homelab subnet: `192.168.88.0/24`
- Node connectivity: mostly `1Gbps Ethernet`

## Kubernetes Cluster

The Kubernetes cluster is managed by the Ansible `cluster` inventory group.

### Master

| Host           | IP               | Board                  | RAM | Primary Storage | Storage Type | Network        |
| -------------- | ---------------- | ---------------------- | --- | --------------- | ------------ | -------------- |
| `alpha-actual` | `192.168.88.201` | Raspberry Pi 4 Model B | 4GB | 500GB USB SSD   | `usb_ssd`    | 1Gbps Ethernet |

### Workers

| Host       | Role Group       | IP               | Board          | RAM | Primary Storage | Storage Type | Network        |
| ---------- | ---------------- | ---------------- | -------------- | --- | --------------- | ------------ | -------------- |
| `bravo`    | `computer`       | `192.168.88.202` | Raspberry Pi 5 | 8GB | 128GB NVMe SSD  | `nvme`       | 1Gbps Ethernet |
| `charlie`  | `computer`       | `192.168.88.203` | Raspberry Pi 5 | 8GB | 128GB NVMe SSD  | `nvme`       | 1Gbps Ethernet |
| `delta`    | `computer`       | `192.168.88.204` | Raspberry Pi 5 | 8GB | 128GB NVMe SSD  | `nvme`       | 1Gbps Ethernet |
| `echo`     | `computer`       | `192.168.88.206` | Raspberry Pi 5 | 8GB | 256GB NVMe SSD  | `nvme`       | 1Gbps Ethernet |
| `kilo`     | `object_storage` | `192.168.88.209` | Raspberry Pi 5 | 4GB | 128GB USB SSD   | `usb_ssd`    | 1Gbps Ethernet |
| `november` | `database`       | `192.168.88.205` | Raspberry Pi 5 | 4GB | 256GB NVMe SSD  | `nvme`       | 1Gbps Ethernet |

### Cluster Totals

- Nodes: 7
- RAM: 44GB
- Primary storage: about 1.5TB
- Control plane: 1 Raspberry Pi node
- Worker capacity: 6 Raspberry Pi nodes

## Kubernetes Scheduling

Node scheduling is configured by `playbooks/kubernetes/setup-master.yml` and `playbooks/kubernetes/setup-worker.yml`.

### Node Labels And Taints

| Host           | Purpose               | Labels                                        | Taints                                             |
| -------------- | --------------------- | --------------------------------------------- | -------------------------------------------------- |
| `alpha-actual` | Control plane         | `node-role.kubernetes.io/control-plane=true`  | `node-role.kubernetes.io/control-plane:NoSchedule` |
| `bravo`        | General worker        | Kubernetes default worker labels              | none                                               |
| `charlie`      | General worker        | Kubernetes default worker labels              | none                                               |
| `delta`        | General worker        | Kubernetes default worker labels              | none                                               |
| `echo`         | General worker        | Kubernetes default worker labels              | none                                               |
| `kilo`         | Object storage worker | `node-role.kubernetes.io/object-storage=true` | `dedicated=object-storage:NoSchedule`              |
| `november`     | Database worker       | `node-role.kubernetes.io/database=true`       | `dedicated=database:NoSchedule`                    |

### Scheduling Intent

- `alpha-actual` runs the K3s control plane and is tainted so normal application pods do not land there.
- `bravo`, `charlie`, `delta`, and `echo` are the default general-purpose worker pool for most workloads.
- `kilo` is reserved for object-storage workloads. Pods must select `node-role.kubernetes.io/object-storage: "true"` and tolerate `dedicated=object-storage:NoSchedule`.
- `november` is reserved for database workloads. Pods must select `node-role.kubernetes.io/database: "true"` and tolerate `dedicated=database:NoSchedule`.

### Workload Placement

| Workload                              | Placement                                                             |
| ------------------------------------- | --------------------------------------------------------------------- |
| K3s server                            | `alpha-actual`                                                        |
| General application workloads         | untainted `computer` workers                                          |
| SeaweedFS                             | `kilo` through the object-storage node selector and toleration        |
| NATS JetStream storage                | `kilo` through the object-storage node selector and toleration        |
| PostgreSQL                            | `november` through the database node selector and toleration          |
| Cert Manager                          | `alpha-actual` through the control-plane node selector and toleration |
| Reloader                              | `alpha-actual` through the control-plane node selector and toleration |
| Trust Manager                         | `alpha-actual` through the control-plane node selector and toleration |
| Descheduler                           | `alpha-actual` through the control-plane node selector and toleration |
| System Upgrade Controller server plan | `alpha-actual` through the control-plane node selector and toleration |
| System Upgrade Controller agent plan  | dedicated worker nodes through a broad `dedicated` toleration         |

### K3s Server Flags

The control plane is installed with these flags:

```bash
--disable servicelb
--disable-cloud-controller
--disable-network-policy
--write-kubeconfig-mode 644
--node-taint node-role.kubernetes.io/control-plane:NoSchedule
```

This means the cluster expects load balancing, cloud-controller behavior, and network policy behavior to be handled by other installed components or left intentionally disabled.

### Node Preparation

Cluster nodes are prepared by `playbooks/kubernetes/initial-setup-node.yml`.

- Swap and zram swap are disabled on cluster nodes.
- GPU memory and CMA are reduced for headless Raspberry Pi operation.
- WiFi and Bluetooth are disabled on cluster nodes.
- Memory cgroups are enabled for Kubernetes.
- Kubernetes network modules `br_netfilter` and `overlay` are loaded.
- Kernel, filesystem, conntrack, TCP, and VM sysctls are tuned per node memory and storage type.
- Longhorn prerequisites are installed only on the `computer` worker group.

## Standalone Nodes

Standalone nodes are part of the homelab inventory but are not Kubernetes cluster members.

| Host     | Role Group | IP               | Board                 | RAM   | Primary Storage | Secondary Storage       | Storage Type | Network                        |
| -------- | ---------- | ---------------- | --------------------- | ----- | --------------- | ----------------------- | ------------ | ------------------------------ |
| `mike`   | `iot`      | `192.168.88.200` | Raspberry Pi Zero 2 W | 0.5GB | 64GB MicroSD    | -                       | `sd`         | 1Gbps Ethernet via USB adapter |
| `sierra` | `nas`      | `192.168.88.207` | x86-64                | 8GB   | SATA SSD (OS)   | 2x 1.8TB HDD (NAS data) | `sata_ssd`   | 1Gbps Ethernet                 |

## Proxy Node

| Host    | Role Group | IP               | Board          | RAM | Primary Storage | Storage Type | Network        |
| ------- | ---------- | ---------------- | -------------- | --- | --------------- | ------------ | -------------- |
| `hotel` | `proxy`    | `192.168.88.208` | Raspberry Pi 5 | 2GB | 64GB MicroSD    | `sd`         | 1Gbps Ethernet |

## Node Notes

### `mike`

USB Ethernet and USB storage tuning are documented in `inventory/host_vars/mike/vars.yml`.

### `romeo`

The former `builder` node is currently decommissioned in `inventory/hosts.yml` because of rack space and power capacity constraints.
