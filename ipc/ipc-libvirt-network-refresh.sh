#!/usr/bin/env bash
set -euo pipefail

# Recreate a libvirt network using the same
# schema as bip-orchestrate-vm/net.xml.template, but with a possibly new IPv4
# machine network.
#
# This is intended to be run during `make ipc` right before host DNS is updated,
# so the host-side libvirt network/bridge matches the new VM address.
#
# Required env:
#   NET_NAME
#   NET_BRIDGE_NAME
#   MACHINE_NETWORK         - IPv4 CIDR, must be /24 (e.g. 192.168.127.0/24)
#
# Optional env:
#   VM_NAME                 - if set, attempt to attach the VM tap (vnet*) to
#                             the network bridge after recreation
#   VIRSH_CONNECT           - libvirt URI (default: qemu:///system)
#

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "ipc-libvirt-network-refresh: $*" >&2; }

NET_NAME="${NET_NAME:-}"
NET_BRIDGE_NAME="${NET_BRIDGE_NAME:-}"
MACHINE_NETWORK="${MACHINE_NETWORK:-}"
VM_NAME="${VM_NAME:-}"
VIRSH_CONNECT="${VIRSH_CONNECT:-qemu:///system}"

[[ -n "${NET_NAME}" ]] || die "NET_NAME is required"
[[ -n "${NET_BRIDGE_NAME}" ]] || die "NET_BRIDGE_NAME is required"
[[ -n "${MACHINE_NETWORK}" ]] || die "MACHINE_NETWORK is required"

if [[ "${MACHINE_NETWORK}" != */24 ]]; then
  die "MACHINE_NETWORK must be an IPv4 /24 CIDR (got: ${MACHINE_NETWORK})"
fi

cidr_ip="${MACHINE_NETWORK%/*}"
if [[ ! "${cidr_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "MACHINE_NETWORK must look like A.B.C.D/24 (got: ${MACHINE_NETWORK})"
fi

IFS='.' read -r o1 o2 o3 o4 <<<"${cidr_ip}"
for o in "${o1}" "${o2}" "${o3}" "${o4}"; do
  [[ "${o}" =~ ^[0-9]+$ ]] || die "Invalid IPv4 in MACHINE_NETWORK (got: ${MACHINE_NETWORK})"
  (( o >= 0 && o <= 255 )) || die "Invalid IPv4 in MACHINE_NETWORK (got: ${MACHINE_NETWORK})"
done

NET_PREFIX="$(echo "${cidr_ip}" | cut -d . -f 1-3)"
GATEWAY="${NET_PREFIX}.1"

virsh_cmd=(sudo virsh --connect="${VIRSH_CONNECT}")

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}"; }
trap cleanup EXIT

xml="${tmpdir}/net.xml"

# Mirror bip-orchestrate-vm/net.xml.template rendering semantics.
cat > "${xml}" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${NET_BRIDGE_NAME}' stp='on' delay='0'/>
  <ip family='ipv4' address='${GATEWAY}' prefix='24'></ip>
</network>
EOF

old_bridge=""
if "${virsh_cmd[@]}" net-dumpxml "${NET_NAME}" >/dev/null 2>&1; then
  old_bridge="$("${virsh_cmd[@]}" net-dumpxml "${NET_NAME}" | awk -F"'" '/<bridge name=/{print $2; exit}')"
fi

log "Refreshing libvirt network ${NET_NAME} (${MACHINE_NETWORK})"
log "Destroying/undefining existing network (if present)"
"${virsh_cmd[@]}" net-destroy "${NET_NAME}" >/dev/null 2>&1 || true
"${virsh_cmd[@]}" net-undefine "${NET_NAME}" >/dev/null 2>&1 || true

log "Defining/starting network from rendered XML (bridge=${NET_BRIDGE_NAME})"
"${virsh_cmd[@]}" net-define "${xml}" >/dev/null
"${virsh_cmd[@]}" net-autostart "${NET_NAME}" >/dev/null
"${virsh_cmd[@]}" net-start "${NET_NAME}" >/dev/null

if [[ -n "${VM_NAME}" ]]; then
  if "${virsh_cmd[@]}" dominfo "${VM_NAME}" >/dev/null 2>&1; then
    state="$("${virsh_cmd[@]}" domstate "${VM_NAME}" 2>/dev/null | tr -d '\r' || true)"
    if echo "${state}" | grep -qi "running"; then
      # Attach any vnet* interfaces for this domain to the network bridge.
      # We intentionally avoid detaching/reattaching via libvirt so we don't
      # change the NIC model/MAC, only its bridge master.
      mapfile -t vnets < <("${virsh_cmd[@]}" domiflist "${VM_NAME}" 2>/dev/null | awk '$1 ~ /^vnet[0-9]+$/ {print $1}')
      if ((${#vnets[@]} == 0)); then
        log "VM ${VM_NAME} is running but no vnet* interfaces found; skipping bridge attachment"
      else
        for vnet in "${vnets[@]}"; do
          log "Attaching ${VM_NAME}:${vnet} to bridge ${NET_BRIDGE_NAME} (old bridge: ${old_bridge:-unknown})"
          sudo ip link set dev "${vnet}" master "${NET_BRIDGE_NAME}" || true
        done
      fi
    else
      log "VM ${VM_NAME} is not running (${state}); skipping bridge attachment"
    fi
  else
    log "VM ${VM_NAME} not found in libvirt; skipping bridge attachment"
  fi
fi

log "Done"


