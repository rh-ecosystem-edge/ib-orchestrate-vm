# IBI / IBU VM orchestration

This repo provides the framework for running Image Base Upgrade (IBU) and
Installation (IBI) on libvirt virtual machines for development, debugging and
experimentation purposes. It also provides framework for performing IP Configuration (IPC) on SNO clusters.

Usage:

- [IBI Usage](README.ibi.md)
- [IBU Usage](README.ibu.md)
- [IPC Usage](ipc/README.md)

## Requirements

For running some of the options in the makefile you might need the following packages:

- `virt-install`
- `nmstate`

Remember to define `PULL_SECRET` not pointing to the file containing it but to the full secret itself, you can convert from the file to the variable by running:

```sh
export PULL_SECRET="$(jq -c . ~/openshift_pull.json)"
```

That will load file contents with jq in compact form and store it in that environment variable.

## IP stack selection (v4 / v6 / dual-stack)

This repo can now drive **single-stack IPv4**, **single-stack IPv6**, and **dual-stack** installs for the seed/target VMs by setting:

- **`IP_STACK`**: one of `v4`, `v6`, `v4v6` (dual-stack, primary v4), `v6v4` (dual-stack, primary v6)

### Network inputs (use `_V4` / `_V6` suffixes)

Defaults live in `network.env`. You can override them via env or make variables:

- **Libvirt machine networks**
  - `NET_SEED_NETWORK_V4`, `NET_SEED_NETWORK_V6`
  - `NET_TARGET_NETWORK_V4`, `NET_TARGET_NETWORK_V6`
- **VM static IPs**
  - `SEED_VM_IP_V4`, `SEED_VM_IP_V6`
  - `TARGET_VM_IP_V4`, `TARGET_VM_IP_V6`
  - `IBI_VM_IP_V4`, `IBI_VM_IP_V6`
- **Cluster/service networks (defaults provided; override as needed)**
  - `CLUSTER_NETWORK_V4`, `CLUSTER_NETWORK_V6`
  - `CLUSTER_SVC_NETWORK_V4`, `CLUSTER_SVC_NETWORK_V6`
  - `CLUSTER_NETWORK_HOST_PREFIX_V4`, `CLUSTER_NETWORK_HOST_PREFIX_V6`

### Example

Run a dual-stack install with primary IPv6:

```sh
export IP_STACK=v6v4
make seed-vm-create
```

### Primary IP for “single address” consumers

In dual-stack (`v4v6` / `v6v4`) we intentionally keep the local dnsmasq records for:

- `api.<cluster>.<domain>`
- `apps.<cluster>.<domain>`

pointing to the **primary** IP only. Some tools resolve a single address and may
prefer IPv6 depending on host settings; using the primary avoids surprises.

## Upstream patch (bip-orchestrate-vm)

The dual-stack/v6 enablement for the vendored `bip-orchestrate-vm` is kept as a git-format patch under `patches/bip-orchestrate-vm/`.
It was based on the approach in upstream PR [MGMT-21493: Enable ABI with DS primary v4 / v6 and single-stack v6](https://github.com/rh-ecosystem-edge/bip-orchestrate-vm/pull/13).
