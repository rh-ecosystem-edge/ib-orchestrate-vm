#!/usr/bin/env bash
set -euo pipefail

# Renders an lca.openshift.io/v1 IPConfig singleton CR to stdout.
#
# Note: This repo uses the shorter "ipc" naming for make targets/docs, but the
# Kubernetes resource remains:
#   kind: IPConfig
#   metadata.name: ipconfig
#
# Inputs (env vars):
#   IPC_STAGE                     (default: Idle)  - one of: Idle, Config, Rollback
#   IPC_IPV4_ADDRESS              (optional)       - e.g. 192.0.2.10
#   IPC_IPV4_MACHINE_NETWORK      (optional)       - e.g. 192.0.2.0/24
#   IPC_IPV4_GATEWAY              (optional)       - e.g. 192.0.2.1
#   IPC_IPV6_ADDRESS              (optional)       - e.g. 2001:db8::1
#   IPC_IPV6_MACHINE_NETWORK      (optional)       - e.g. 2001:db8::/64
#   IPC_IPV6_GATEWAY              (optional)       - e.g. 2001:db8::1 (or link-local fe80::/10)
#   IPC_DNS_SERVERS               (optional)       - comma/space separated list of IPs
#   IPC_VLAN_ID                   (optional)       - integer (>=1)
#   IPC_DNS_FILTER_OUT_FAMILY     (optional)       - one of: ipv4, ipv6, none
#   IPC_AUTO_ROLLBACK_TIMEOUT_SECONDS (optional)   - integer seconds (0 allowed)
#   IPC_SKIP_PRE_CLUSTER_HEALTHCHECKS (optional)    - if set to "true"/"1"/"yes", sets the
#                                                     ipconfig-skip-pre-configuration-cluster-health-checks annotation.
#   IPC_SKIP_POST_CLUSTER_HEALTHCHECKS (optional)   - if set to "true"/"1"/"yes", sets the
#                                                     ipconfig-skip-post-configuration-cluster-health-checks annotation.
#   IPC_SKIP_CLUSTER_HEALTHCHECKS (optional)        - shorthand: if set to "true"/"1"/"yes", skips BOTH pre and post.
#
#   IPC_DISABLE_AUTO_ROLLBACK_INIT_MONITOR (optional) - defaults to "true". When true, sets:
#                                                      auto-rollback-on-failure.lca.openshift.io/init-monitor: Disabled
#   IPC_DISABLE_AUTO_ROLLBACK_IP_CONFIG_RUN (optional) - defaults to "true". When true, sets:
#                                                        auto-rollback-on-failure.lca.openshift.io/ip-config-run: Disabled
#   IPC_RECERT_IMAGE (optional)                      - if set, sets:
#                                                      lca.openshift.io/recert-image: <value>
#   IPC_RECERT_PULL_SECRET (optional)                - if set, sets:
#                                                      lca.openshift.io/recert-pull-secret: <value>

stage="${IPC_STAGE:-Idle}"

ipv4_address="${IPC_IPV4_ADDRESS:-}"
ipv4_mn="${IPC_IPV4_MACHINE_NETWORK:-}"
ipv4_gw="${IPC_IPV4_GATEWAY:-}"

ipv6_address="${IPC_IPV6_ADDRESS:-}"
ipv6_mn="${IPC_IPV6_MACHINE_NETWORK:-}"
ipv6_gw="${IPC_IPV6_GATEWAY:-}"

dns_servers_raw="${IPC_DNS_SERVERS:-}"
vlan_id="${IPC_VLAN_ID:-}"
dns_filter="${IPC_DNS_FILTER_OUT_FAMILY:-}"
arb_timeout="${IPC_AUTO_ROLLBACK_TIMEOUT_SECONDS:-}"

skip_cluster_healthchecks="${IPC_SKIP_CLUSTER_HEALTHCHECKS:-}"
skip_pre_cluster_healthchecks="${IPC_SKIP_PRE_CLUSTER_HEALTHCHECKS:-}"
skip_post_cluster_healthchecks="${IPC_SKIP_POST_CLUSTER_HEALTHCHECKS:-}"

disable_auto_rollback_init_monitor="${IPC_DISABLE_AUTO_ROLLBACK_INIT_MONITOR:-true}"
disable_auto_rollback_ip_config_run="${IPC_DISABLE_AUTO_ROLLBACK_IP_CONFIG_RUN:-true}"

recert_image="${IPC_RECERT_IMAGE:-}"
recert_pull_secret="${IPC_RECERT_PULL_SECRET:-}"

# By default, do NOT skip health checks (i.e., do NOT emit skip annotations).
should_skip_pre_cluster_healthchecks=false
should_skip_post_cluster_healthchecks=false

case "${skip_cluster_healthchecks,,}" in
  "1"|"true"|"yes")
    should_skip_pre_cluster_healthchecks=true
    should_skip_post_cluster_healthchecks=true
    ;;
esac

case "${skip_pre_cluster_healthchecks,,}" in
  "1"|"true"|"yes") should_skip_pre_cluster_healthchecks=true ;;
esac

case "${skip_post_cluster_healthchecks,,}" in
  "1"|"true"|"yes") should_skip_post_cluster_healthchecks=true ;;
esac

should_disable_auto_rollback_init_monitor=false
case "${disable_auto_rollback_init_monitor,,}" in
  ""|"1"|"true"|"yes") should_disable_auto_rollback_init_monitor=true ;;
esac

should_disable_auto_rollback_ip_config_run=false
case "${disable_auto_rollback_ip_config_run,,}" in
  ""|"1"|"true"|"yes") should_disable_auto_rollback_ip_config_run=true ;;
esac

emit_dns_servers() {
  local raw="${1}"
  # Split on comma and/or whitespace.
  # shellcheck disable=SC2206
  local arr=( ${raw//,/ } )
  if ((${#arr[@]} == 0)); then
    return 0
  fi
  echo "  dnsServers:"
  local s
  for s in "${arr[@]}"; do
    [[ -n "${s}" ]] || continue
    echo "    - ${s}"
  done
}

cat <<EOF
apiVersion: lca.openshift.io/v1
kind: IPConfig
metadata:
  name: ipconfig
EOF

if [[ "${should_skip_pre_cluster_healthchecks}" == "true" ]] || \
   [[ "${should_skip_post_cluster_healthchecks}" == "true" ]] || \
   [[ -n "${recert_image}" ]] || \
   [[ -n "${recert_pull_secret}" ]] || \
   [[ "${should_disable_auto_rollback_init_monitor}" == "true" ]] || \
   [[ "${should_disable_auto_rollback_ip_config_run}" == "true" ]]; then
  echo "  annotations:"
fi

if [[ "${should_skip_pre_cluster_healthchecks}" == "true" ]]; then
  echo "    lca.openshift.io/ipconfig-skip-pre-configuration-cluster-health-checks: \"\""
fi

if [[ "${should_skip_post_cluster_healthchecks}" == "true" ]]; then
  echo "    lca.openshift.io/ipconfig-skip-post-configuration-cluster-health-checks: \"\""
fi

if [[ -n "${recert_image}" ]]; then
  echo "    lca.openshift.io/recert-image: ${recert_image}"
fi

if [[ -n "${recert_pull_secret}" ]]; then
  echo "    lca.openshift.io/recert-pull-secret: ${recert_pull_secret}"
fi

# These annotations disable auto-rollback behaviors. The operator expects the literal value "Disabled".
if [[ "${should_disable_auto_rollback_init_monitor}" == "true" ]]; then
  echo "    auto-rollback-on-failure.lca.openshift.io/init-monitor: Disabled"
fi

if [[ "${should_disable_auto_rollback_ip_config_run}" == "true" ]]; then
  echo "    auto-rollback-on-failure.lca.openshift.io/ip-config-run: Disabled"
fi

cat <<EOF
spec:
  stage: ${stage}
EOF

if [[ -n "${ipv4_address}" ]]; then
  cat <<EOF
  ipv4:
    address: ${ipv4_address}
EOF
  if [[ -n "${ipv4_mn}" ]]; then
    echo "    machineNetwork: ${ipv4_mn}"
  fi
  if [[ -n "${ipv4_gw}" ]]; then
    echo "    gateway: ${ipv4_gw}"
  fi
fi

if [[ -n "${ipv6_address}" ]]; then
  cat <<EOF
  ipv6:
    address: ${ipv6_address}
EOF
  if [[ -n "${ipv6_mn}" ]]; then
    echo "    machineNetwork: ${ipv6_mn}"
  fi
  if [[ -n "${ipv6_gw}" ]]; then
    echo "    gateway: ${ipv6_gw}"
  fi
fi

if [[ -n "${dns_servers_raw}" ]]; then
  emit_dns_servers "${dns_servers_raw}"
fi

if [[ -n "${vlan_id}" ]]; then
  if [[ ! "${vlan_id}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: IPC_VLAN_ID must be an integer (got: ${vlan_id})" >&2
    exit 2
  fi
  # CRD requires vlanID >= 1 when present. Treat 0 as "unset".
  if (( vlan_id >= 1 )); then
    echo "  vlanID: ${vlan_id}"
  fi
fi

if [[ -n "${dns_filter}" ]]; then
  echo "  dnsFilterOutFamily: ${dns_filter}"
fi

if [[ -n "${arb_timeout}" ]]; then
  if [[ ! "${arb_timeout}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: IPC_AUTO_ROLLBACK_TIMEOUT_SECONDS must be an integer (got: ${arb_timeout})" >&2
    exit 2
  fi
  cat <<EOF
  autoRollbackOnFailure:
    initMonitorTimeoutSeconds: ${arb_timeout}
EOF
fi


