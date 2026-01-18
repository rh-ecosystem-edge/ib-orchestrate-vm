#!/usr/bin/env bash
set -euo pipefail

# Update host-side dnsmasq records for api/apps to point at the new IP and restart NetworkManager.
#
# Required env:
#   CLUSTER_NAME   - OpenShift cluster name (e.g. ibi)
#   BASE_DOMAIN    - OpenShift base domain (e.g. ibo1.redhat.com)
#
# IP selection (first non-empty wins):
#   HOST_IP, IPC_IPV4_ADDRESS, IPC_IPV6_ADDRESS
#
# Optional env:
#   DNSMASQ_CONF   - dnsmasq config file path (default: /etc/NetworkManager/dnsmasq.d/bip.conf)

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "ipc-host-dns-update: $*" >&2; }

CLUSTER_NAME="${CLUSTER_NAME:-}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/NetworkManager/dnsmasq.d/bip.conf}"

HOST_IP="${HOST_IP:-}"
IPC_IPV4_ADDRESS="${IPC_IPV4_ADDRESS:-}"
IPC_IPV6_ADDRESS="${IPC_IPV6_ADDRESS:-}"

[[ -n "${CLUSTER_NAME}" ]] || die "CLUSTER_NAME is required"
[[ -n "${BASE_DOMAIN}" ]] || die "BASE_DOMAIN is required"

if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="${IPC_IPV4_ADDRESS:-}"
fi
if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="${IPC_IPV6_ADDRESS:-}"
fi
[[ -n "${HOST_IP}" ]] || die "HOST_IP (or IPC_IPV4_ADDRESS/IPC_IPV6_ADDRESS) is required"

api="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
apps="apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}"; }
trap cleanup EXIT

orig="${tmpdir}/bip.conf.orig"
new="${tmpdir}/bip.conf.new"

log "Updating dnsmasq records in ${DNSMASQ_CONF} -> ${HOST_IP} (${api}, ${apps})"

sudo mkdir -p "$(dirname "${DNSMASQ_CONF}")"
if sudo test -f "${DNSMASQ_CONF}"; then
  sudo cat "${DNSMASQ_CONF}" > "${orig}"
else
  : > "${orig}"
fi

awk -v api="${api}" -v apps="${apps}" '
  $0 !~ "^address=/" api "/" && $0 !~ "^address=/" apps "/" { print }
' "${orig}" > "${new}"

{
  echo "address=/${api}/${HOST_IP}"
  echo "address=/${apps}/${HOST_IP}"
} >> "${new}"

sudo tee "${DNSMASQ_CONF}" < "${new}" >/dev/null

log "Restarting NetworkManager..."
sudo systemctl restart NetworkManager.service
log "Done"


