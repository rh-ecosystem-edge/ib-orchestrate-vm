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
#   MACHINE_NETWORK_V4      - IPv4 CIDR, must be /24 (e.g. 192.168.127.0/24)
#
# Optional env:
#   IP_STACK                - v4 / v6 / v4v6 / v6v4 (default: v4)
#   MACHINE_NETWORK_V6      - IPv6 CIDR (e.g. fd00:127::/64) (required when IP_STACK includes v6)
#   GATEWAY_V6              - IPv6 gateway address (if unset and v6 is enabled, defaults to <network>::1)
#   MACHINE_NETWORK         - legacy alias for MACHINE_NETWORK_V4 (backwards compatible)
#   VM_NAME                 - if set, attempt to attach the VM tap (vnet*) to
#                             the network bridge after recreation
#   VIRSH_CONNECT           - libvirt URI (default: qemu:///system)
#

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "ipc-libvirt-network-refresh: $*" >&2; }

NET_NAME="${NET_NAME:-}"
NET_BRIDGE_NAME="${NET_BRIDGE_NAME:-}"
IP_STACK="${IP_STACK:-v4}"
MACHINE_NETWORK_V4="${MACHINE_NETWORK_V4:-${MACHINE_NETWORK:-}}"
MACHINE_NETWORK_V6="${MACHINE_NETWORK_V6:-}"
GATEWAY_V6="${GATEWAY_V6:-}"
VM_NAME="${VM_NAME:-}"
VIRSH_CONNECT="${VIRSH_CONNECT:-qemu:///system}"

[[ -n "${NET_NAME}" ]] || die "NET_NAME is required"
[[ -n "${NET_BRIDGE_NAME}" ]] || die "NET_BRIDGE_NAME is required"

stack_order=()
case "${IP_STACK}" in
  v4) stack_order=(v4) ;;
  v6) stack_order=(v6) ;;
  v4v6) stack_order=(v4 v6) ;;
  v6v4) stack_order=(v6 v4) ;;
  *) die "Invalid IP_STACK=${IP_STACK}. Expected one of: v4, v6, v4v6, v6v4" ;;
esac

if printf '%s\n' "${stack_order[@]}" | grep -qx 'v4'; then
  [[ -n "${MACHINE_NETWORK_V4}" ]] || die "IP_STACK=${IP_STACK} requires MACHINE_NETWORK_V4 to be set (or legacy MACHINE_NETWORK)"
  if [[ "${MACHINE_NETWORK_V4}" != */24 ]]; then
    die "MACHINE_NETWORK_V4 must be an IPv4 /24 CIDR (got: ${MACHINE_NETWORK_V4})"
  fi
fi

if printf '%s\n' "${stack_order[@]}" | grep -qx 'v6'; then
  [[ -n "${MACHINE_NETWORK_V6}" ]] || die "IP_STACK=${IP_STACK} requires MACHINE_NETWORK_V6 to be set"
  if [[ "${MACHINE_NETWORK_V6}" != */* ]]; then
    die "MACHINE_NETWORK_V6 must be an IPv6 CIDR (got: ${MACHINE_NETWORK_V6})"
  fi
fi

v4_gateway=""
if printf '%s\n' "${stack_order[@]}" | grep -qx 'v4'; then
  cidr_ip="${MACHINE_NETWORK_V4%/*}"
  if [[ ! "${cidr_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "MACHINE_NETWORK_V4 must look like A.B.C.D/24 (got: ${MACHINE_NETWORK_V4})"
  fi

  IFS='.' read -r o1 o2 o3 o4 <<<"${cidr_ip}"
  for o in "${o1}" "${o2}" "${o3}" "${o4}"; do
    [[ "${o}" =~ ^[0-9]+$ ]] || die "Invalid IPv4 in MACHINE_NETWORK_V4 (got: ${MACHINE_NETWORK_V4})"
    (( o >= 0 && o <= 255 )) || die "Invalid IPv4 in MACHINE_NETWORK_V4 (got: ${MACHINE_NETWORK_V4})"
  done

  NET_PREFIX="$(echo "${cidr_ip}" | cut -d . -f 1-3)"
  v4_gateway="${NET_PREFIX}.1"
fi

v6_gateway=""
v6_prefix=""
if printf '%s\n' "${stack_order[@]}" | grep -qx 'v6'; then
  v6_prefix="${MACHINE_NETWORK_V6#*/}"
  if [[ "${GATEWAY_V6}" != "" ]]; then
    v6_gateway="${GATEWAY_V6}"
  else
    # Default gateway to <network>::1 (same convention as bip-orchestrate-vm net.xml rendering).
    v6_gateway="$(python3 - <<'PY'
import ipaddress, os
cidr = os.environ["MACHINE_NETWORK_V6"]
n = ipaddress.IPv6Network(cidr, strict=False)
gw = ipaddress.IPv6Address(int(n.network_address) + 1)
print(gw)
PY
)"
  fi
fi

virsh_cmd=(sudo virsh --connect="${VIRSH_CONNECT}")

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}"; }
trap cleanup EXIT

xml="${tmpdir}/net.xml"

# Mirror bip-orchestrate-vm/net.xml.template rendering semantics.
{
  echo "<network>"
  echo "  <name>${NET_NAME}</name>"
  echo "  <forward mode='nat'/>"
  echo "  <bridge name='${NET_BRIDGE_NAME}' stp='on' delay='0'/>"
  for fam in "${stack_order[@]}"; do
    if [[ "${fam}" == "v4" ]]; then
      echo "  <ip family='ipv4' address='${v4_gateway}' prefix='24'></ip>"
    else
      echo "  <ip family='ipv6' address='${v6_gateway}' prefix='${v6_prefix}'></ip>"
    fi
  done
  echo "</network>"
} > "${xml}"

old_bridge=""
if "${virsh_cmd[@]}" net-dumpxml "${NET_NAME}" >/dev/null 2>&1; then
  old_bridge="$("${virsh_cmd[@]}" net-dumpxml "${NET_NAME}" | awk -F"'" '/<bridge name=/{print $2; exit}')"
fi

log "Refreshing libvirt network ${NET_NAME} (IP_STACK=${IP_STACK})"
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


