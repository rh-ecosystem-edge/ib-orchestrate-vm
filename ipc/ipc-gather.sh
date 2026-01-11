#!/usr/bin/env bash
#
# Gather debug artifacts for the ipc flow.
# Best-effort: this script tries to collect as much as possible and should not fail the whole run
# just because one command fails.
#
# Inputs (all optional):
# - IPC_KUBECONFIG / SNO_KUBECONFIG / KUBECONFIG: kubeconfig path for oc
# - ARTIFACT_DIR: destination directory (defaults under IPC_WORK_DIR)
# - IPC_WORK_DIR: used only for default ARTIFACT_DIR
# - SSH_FLAGS: ssh options (this repo's Makefile provides a good default)
# - VM_SSH_USER: defaults to core
# - IBI_VM_IP / IPC_IPV4_ADDRESS / IPC_IPV6_ADDRESS: candidate SSH IPs to reach the node
#
set -Eeuo pipefail

ts() { date --iso-8601=seconds; }
log() { echo "[$(ts)] $*" >&2; }

ARTIFACT_DIR="${ARTIFACT_DIR:-}"
IPC_WORK_DIR="${IPC_WORK_DIR:-ipc-workdir}"
if [[ -z "${ARTIFACT_DIR}" ]]; then
  ARTIFACT_DIR="${IPC_WORK_DIR}/artifacts/ipc-gather-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "${ARTIFACT_DIR}"

COMMANDS_LOG="${ARTIFACT_DIR}/commands.log"
touch "${COMMANDS_LOG}"

try_sh() {
  local cmd="$1"
  log "+ ${cmd}"
  {
    echo "[$(ts)] + ${cmd}"
    bash -o pipefail -c "${cmd}"
    echo "[$(ts)] + OK"
  } >>"${COMMANDS_LOG}" 2>&1 || {
    local rc=$?
    log "WARN: command failed (rc=${rc}): ${cmd}"
    echo "[$(ts)] + FAILED (rc=${rc})" >>"${COMMANDS_LOG}" 2>&1 || true
    return 0
  }
}

write_file_best_effort() {
  local out="$1"
  shift
  local cmd="$*"
  try_sh "${cmd} > \"${out}\""
}

dedupe_words() {
  # preserve order, split on whitespace
  awk '
    {
      for (i=1; i<=NF; i++) {
        if (!seen[$i]++) printf "%s%s", $i, (i==NF ? ORS : OFS)
      }
    }
  ' OFS=' '
}

KUBECONFIG_PATH="${IPC_KUBECONFIG:-${SNO_KUBECONFIG:-${KUBECONFIG:-}}}"
if [[ -z "${KUBECONFIG_PATH}" && -f "ibi-iso-work-dir/auth/kubeconfig" ]]; then
  KUBECONFIG_PATH="ibi-iso-work-dir/auth/kubeconfig"
fi
if [[ -n "${KUBECONFIG_PATH}" ]]; then
  if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
    log "WARN: kubeconfig not found at: ${KUBECONFIG_PATH} (will still try oc if KUBECONFIG is set elsewhere)"
  else
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
else
  log "WARN: no kubeconfig path provided (set IPC_KUBECONFIG/SNO_KUBECONFIG/KUBECONFIG)"
fi

VM_SSH_USER="${VM_SSH_USER:-core}"
SSH_FLAGS="${SSH_FLAGS:-}"
OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-10s}"

log "IPC gather starting"
log "ARTIFACT_DIR=${ARTIFACT_DIR}"
log "KUBECONFIG=${KUBECONFIG:-<unset>}"

mkdir -p "${ARTIFACT_DIR}/cluster"

# Cluster artifacts
write_file_best_effort "${ARTIFACT_DIR}/cluster/ip-config.yaml" "oc --request-timeout=${OC_REQUEST_TIMEOUT} get ipc ipconfig -o yaml"
write_file_best_effort "${ARTIFACT_DIR}/cluster/nodes.yaml" "oc --request-timeout=${OC_REQUEST_TIMEOUT} get nodes -o yaml"
write_file_best_effort "${ARTIFACT_DIR}/cluster/cluster-operators.yaml" "oc --request-timeout=${OC_REQUEST_TIMEOUT} get co -o yaml"
write_file_best_effort "${ARTIFACT_DIR}/cluster/cluster-version.yaml" "oc --request-timeout=${OC_REQUEST_TIMEOUT} get clusterversion -o yaml"
write_file_best_effort "${ARTIFACT_DIR}/cluster/cluster-master-mcp.yaml" "oc --request-timeout=${OC_REQUEST_TIMEOUT} get mcp master -o yaml"
write_file_best_effort "${ARTIFACT_DIR}/cluster/cluster-events.yaml" "oc --request-timeout=${OC_REQUEST_TIMEOUT} get events -A -o yaml"

mkdir -p "${ARTIFACT_DIR}/lifecycle-agent"
# LCA operator/pod logs
LCA_NS="openshift-lifecycle-agent"
write_file_best_effort "${ARTIFACT_DIR}/lifecycle-agent/pods.yaml" "oc --request-timeout=${OC_REQUEST_TIMEOUT} get pods -n ${LCA_NS} -o yaml"

LCA_POD_NAME="$(
  oc --request-timeout="${OC_REQUEST_TIMEOUT}" get pods -n "${LCA_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true
)"
if [[ -n "${LCA_POD_NAME}" ]]; then
  write_file_best_effort "${ARTIFACT_DIR}/lifecycle-agent/current.log" "oc --request-timeout=${OC_REQUEST_TIMEOUT} logs -n ${LCA_NS} ${LCA_POD_NAME} --all-containers=true"
  write_file_best_effort "${ARTIFACT_DIR}/lifecycle-agent/previous.log" "oc --request-timeout=${OC_REQUEST_TIMEOUT} logs -n ${LCA_NS} ${LCA_POD_NAME} --all-containers=true --previous"
else
  log "WARN: could not determine a pod name in namespace ${LCA_NS}"
fi

# Candidate node IPs (for SSH-based collection)

node_internal_ips="$(
  oc --request-timeout="${OC_REQUEST_TIMEOUT}" get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{" "}{end}{end}' 2>/dev/null || true
)"

candidate_ips="$(
  printf '%s\n' \
    "${IPC_IPV4_ADDRESS:-}" \
    "${IPC_IPV6_ADDRESS:-}" \
    "${IBI_VM_IP:-}" \
    "${HOST_IP:-}" \
    "${node_internal_ips}" \
  | tr '\n' ' ' | xargs -n1 2>/dev/null | sed '/^$/d' | dedupe_words | tr '\n' ' '
)"

can_connect_22() {
  local host="$1"
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/22" >/dev/null 2>&1
}

REACHABLE_NODE_IP=""
for ip in ${candidate_ips}; do
  if can_connect_22 "${ip}"; then
    REACHABLE_NODE_IP="${ip}"
    break
  fi
done

if [[ -z "${REACHABLE_NODE_IP}" ]]; then
  log "WARN: could not reach any candidate IP on port 22; skipping SSH-based collection"
  log "IPC gather complete (partial). Artifacts at: ${ARTIFACT_DIR}"
  exit 0
fi

log "Using reachable node IP: ${REACHABLE_NODE_IP}"

# Build ssh command (split SSH_FLAGS intentionally on whitespace).
# shellcheck disable=SC2206
ssh_flags_arr=(${SSH_FLAGS})
ssh_base=(ssh "${ssh_flags_arr[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
ssh_dest="${VM_SSH_USER}@${REACHABLE_NODE_IP}"

mkdir -p "${ARTIFACT_DIR}/lca-cli"

try_sh "${ssh_base[*]} ${ssh_dest} 'sudo journalctl -u lca-ipconfig-pre-pivot --no-pager' > \"${ARTIFACT_DIR}/lca-cli/pre-pivot.log\""
try_sh "${ssh_base[*]} ${ssh_dest} 'sudo journalctl -u ip-configuration --no-pager' > \"${ARTIFACT_DIR}/lca-cli/ip-configuration.log\""
try_sh "${ssh_base[*]} ${ssh_dest} 'sudo journalctl -u lca-init-monitor --no-pager' > \"${ARTIFACT_DIR}/lca-cli/lca-init-monitor.log\""
try_sh "${ssh_base[*]} ${ssh_dest} 'sudo journalctl -u lca-ipconfig-rollback --no-pager' > \"${ARTIFACT_DIR}/lca-cli/rollback.log\""

# Pull /var/lib/lca/workspace (exclude kubeconfig-crypto)
try_sh "${ssh_base[*]} ${ssh_dest} 'sudo tar -C /var/lib/lca --exclude=workspace/kubeconfig-crypto -cf - workspace' | tar -C \"${ARTIFACT_DIR}/node\" -xf -"

log "IPC gather complete. Artifacts at: ${ARTIFACT_DIR}"


