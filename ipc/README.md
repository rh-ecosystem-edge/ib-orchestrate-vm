# IP configuration flow (IPC) for IBI clusters

This repo runs the **Lifecycle Agent** `IPConfig` flow on an **IBI-installed** SNO **created by this repo** (see `README.ibi.md`).
We assume the IBI environment (VM + host configuration) follows this repo’s IBI flow
The flow is implemented by creating/updating the cluster-scoped singleton CR:

- `kind: IPConfig`
- `metadata.name: ipconfig`

and then driving stage transitions (`Idle` → `Config`, and optionally `Rollback`) the same way the repo drives `ImageBasedUpgrade` stages.

For the upstream design/background, see the lifecycle-agent PR doc: [openshift-kni/lifecycle-agent#4068](https://github.com/openshift-kni/lifecycle-agent/pull/4068).

## Prerequisites

- An **IBI** cluster installed according to `README.ibi.md`
- `oc` access to the cluster (**use the IBI kubeconfig**; see below)
- The **lifecycle-agent operator** installed on the cluster (the `ipc` target can deploy it)
- Host DNS configured as described below (the IBI make targets configure this via `host-net-config`)

### DNS assumptions (IBI)

The IBI flow configures the host to resolve the cluster endpoints through NetworkManager dnsmasq:

- `api.ibi.<NET_TARGET_DOMAIN>` → the VM IP
- `apps.ibi.<NET_TARGET_DOMAIN>` → the VM IP

This is done by `make ibi-vm` via the `host-net-config` target (see `Makefile.ibi` and `bip-orchestrate-vm/host-net-config.sh`).

When you change the VM IP/network with IPC, **the host-side DNS and libvirt network may need to be updated too** (depending on how your VM networking is set up). This repo no longer automates that host-side cutover; use the host tooling (for example `bip-orchestrate-vm/host-net-config.sh`) as appropriate for your environment.

## Quick start

Run an IPv4 change:

```bash
make ipc \
  IPC_IPV4_ADDRESS=192.168.127.80 \
  IPC_IPV4_MACHINE_NETWORK=192.168.127.0/24 \
  IPC_IPV4_GATEWAY=192.168.127.1 \
  IPC_DNS_SERVERS="192.168.127.1,8.8.8.8" \
  IPC_DNS_FILTER_OUT_FAMILY=none
```

The `ipc*` targets are defined in `ipc/Makefile.ipc` (included by the top-level `Makefile`).

Run a dual-stack change:

```bash
make ipc \
  IPC_IPV4_ADDRESS=192.168.127.80 \
  IPC_IPV4_MACHINE_NETWORK=192.168.127.0/24 \
  IPC_IPV4_GATEWAY=192.168.127.1 \
  IPC_IPV6_ADDRESS=fd00:127::80 \
  IPC_IPV6_MACHINE_NETWORK=fd00:127::/64 \
  IPC_IPV6_GATEWAY=fd00:127::1 \
  IPC_DNS_SERVERS="192.168.127.1 fd00:127::1" \
  IPC_DNS_FILTER_OUT_FAMILY=none
```

## Inputs

- **`IPC_IPV4_ADDRESS`**: new IPv4 address (omit for IPv6-only)
- **`IPC_IPV4_MACHINE_NETWORK`**: new IPv4 machine network CIDR
- **`IPC_IPV4_GATEWAY`**: new IPv4 default gateway
- **`IPC_IPV6_ADDRESS`**: new IPv6 address (omit for IPv4-only)
- **`IPC_IPV6_MACHINE_NETWORK`**: new IPv6 machine network CIDR
- **`IPC_IPV6_GATEWAY`**: new IPv6 default gateway (link-local allowed)
- **`IPC_DNS_SERVERS`**: ordered list of DNS servers (comma and/or space separated)
- **`IPC_VLAN_ID`**: VLAN ID (integer >= 1). If unset/0, VLAN is not configured.
- **`IPC_DNS_FILTER_OUT_FAMILY`**: `ipv4` / `ipv6` / `none` (DNS response filtering on dual-stack)
- **`IPC_AUTO_ROLLBACK_TIMEOUT_SECONDS`**: optional init-monitor timeout used by auto-rollback logic
- **`IPC_SKIP_CLUSTER_HEALTHCHECKS`**: set to `true`/`1`/`yes` to **skip** BOTH pre and post cluster health checks by setting:
  - `lca.openshift.io/ipconfig-skip-pre-configuration-cluster-health-checks`
  - `lca.openshift.io/ipconfig-skip-post-configuration-cluster-health-checks`
- **`IPC_SKIP_PRE_CLUSTER_HEALTHCHECKS`** / **`IPC_SKIP_POST_CLUSTER_HEALTHCHECKS`**: skip pre/post health checks individually.
- **`IPC_DISABLE_AUTO_ROLLBACK_INIT_MONITOR`**: defaults to `true` (disables init-monitor auto-rollback) by setting
  `auto-rollback-on-failure.lca.openshift.io/init-monitor: Disabled`.
- **`IPC_DISABLE_AUTO_ROLLBACK_IP_CONFIG_RUN`**: defaults to `true` (disables ip-config-run auto-rollback) by setting
  `auto-rollback-on-failure.lca.openshift.io/ip-config-run: Disabled`.
- **`IPC_WAIT_FOR_IBU_IDLE`**: set to `true`/`1`/`yes` to wait for `ibu/upgrade` to become Idle *if present* (optional gating for IBI-based flows).
- **`IPC_RECERT_IMAGE`**: set to override recert image (annotation `lca.openshift.io/recert-image`)
- **`IPC_RECERT_PULL_SECRET`**: set to override recert pull secret name (annotation `lca.openshift.io/recert-pull-secret`)

## Observing progress

```bash
oc --kubeconfig ibi-iso-work-dir/auth/kubeconfig get ipc ipconfig -o yaml
oc --kubeconfig ibi-iso-work-dir/auth/kubeconfig get ipc ipconfig
```

## Gathering logs

Collect best-effort debug artifacts for the IPC flow (IPConfig CR, lifecycle-agent pod logs, and
node-side `journalctl` + `/var/lib/lca/workspace` when SSH is reachable):

```bash
make ipc-gather
```

Optionally override output directory:

```bash
make ipc-gather ARTIFACT_DIR=/tmp/ipc-artifacts
```

Optionally provide extra candidate SSH IPs (useful if the API is down but the node is reachable):

```bash
make ipc-gather IPC_IPV4_OLD=192.168.127.74 IPC_IPV4_NEW=192.168.127.80
```

## Rollback

```bash
make ipc-rollback
```


