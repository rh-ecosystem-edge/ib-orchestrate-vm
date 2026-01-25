IPC_WORK_DIR ?= ipc-workdir

IPC_TIMEOUT_SECONDS ?= 3600
IPC_WAIT_POLL_SECONDS ?= 10

# Directory of this makefile (used to reference sibling IPC scripts regardless of CWD).
IPC_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

# Kubeconfig to use for IPC targets (defaults to the repo's current IBI_KUBECONFIG).
# You can override with an absolute path:
# make ipc IPC_KUBECONFIG=/path/to/kubeconfig
IPC_KUBECONFIG ?= $(IBI_KUBECONFIG)

# If true, wait for IBU to be Idle before starting IPC. This only applies to clusters
# that have the IBU CR installed (e.g. IBI-based flows); on other clusters this is skipped.
IPC_WAIT_FOR_IBU_IDLE ?= false

# Desired config inputs (set by user when running targets)
IPC_IPV4_ADDRESS ?=
IPC_IPV4_MACHINE_NETWORK ?=
IPC_IPV4_GATEWAY ?=
IPC_IPV6_ADDRESS ?=
IPC_IPV6_MACHINE_NETWORK ?=
IPC_IPV6_GATEWAY ?=
IPC_DNS_SERVERS ?=
IPC_VLAN_ID ?=
IPC_DNS_FILTER_OUT_FAMILY ?=
IPC_AUTO_ROLLBACK_TIMEOUT_SECONDS ?=

# Health-check skip controls (by default, do NOT emit skip annotations).
IPC_SKIP_CLUSTER_HEALTHCHECKS ?=
IPC_SKIP_PRE_CLUSTER_HEALTHCHECKS ?=
IPC_SKIP_POST_CLUSTER_HEALTHCHECKS ?=

# Optional annotations
IPC_RECERT_IMAGE ?=
IPC_RECERT_PULL_SECRET ?=

# Auto-rollback disable annotations (default: disabled)
IPC_DISABLE_AUTO_ROLLBACK_INIT_MONITOR ?= true
IPC_DISABLE_AUTO_ROLLBACK_IP_CONFIG_RUN ?= true

# When IPC changes the VM IP/machineNetwork, also update host-side dnsmasq
# records for api/apps to match the new address (useful when the API endpoint moves).
IPC_BASE_DOMAIN ?= $(IBI_DOMAIN)
IPC_CLUSTER_NAME ?= $(IBI_CLUSTER_NAME)

# This updates /etc/NetworkManager/dnsmasq.d/bip.conf and restarts NetworkManager.
IPC_DNSMASQ_CONF ?= /etc/NetworkManager/dnsmasq.d/bip.conf

ARTIFACT_DIR ?= $(IPC_WORK_DIR)/artifacts

# Prefer the primary IP family in dual-stack, following the repo-wide IP_STACK convention.
# If IP_STACK is unset, default to IPv4 primary (backwards compatible).
IPC_STACK_PRIMARY_FAM ?= $(if $(filter v6 v6v4,$(IP_STACK)),V6,V4)
IPC_HOST_IP_PRIMARY ?= $(if $(filter V6,$(IPC_STACK_PRIMARY_FAM)),$(IPC_IPV6_ADDRESS),$(IPC_IPV4_ADDRESS))

.PHONY: ipc-host-dns-update
ipc-host-dns-update: ## Update host dnsmasq api/apps records to the new IP (restarts NetworkManager)
	@HOST_IP="$(or $(IPC_HOST_IP_PRIMARY),$(IPC_IPV4_ADDRESS),$(IPC_IPV6_ADDRESS))" \
	IP_STACK="$(IP_STACK)" \
	IPC_IPV4_ADDRESS="$(IPC_IPV4_ADDRESS)" \
	IPC_IPV6_ADDRESS="$(IPC_IPV6_ADDRESS)" \
	CLUSTER_NAME="$(IPC_CLUSTER_NAME)" \
	BASE_DOMAIN="$(IPC_BASE_DOMAIN)" \
	DNSMASQ_CONF="$(IPC_DNSMASQ_CONF)" \
		bash "$(IPC_DIR)ipc-host-dns-update.sh"

.PHONY: ipc-libvirt-network-refresh
ipc-libvirt-network-refresh:
	@NET_NAME="$(NET_TARGET_NAME)" \
	NET_BRIDGE_NAME="$(NET_TARGET_BRIDGE_NAME)" \
	IP_STACK="$(IP_STACK)" \
	MACHINE_NETWORK_V4="$(or $(IPC_IPV4_MACHINE_NETWORK),$(NET_TARGET_NETWORK))" \
	MACHINE_NETWORK_V6="$(IPC_IPV6_MACHINE_NETWORK)" \
	GATEWAY_V6="$(IPC_IPV6_GATEWAY)" \
	VM_NAME="$(IBI_VM_NAME)" \
	VIRSH_CONNECT="$(VIRSH_CONNECT)" \
		bash "$(IPC_DIR)ipc-libvirt-network-refresh.sh"

.PHONY: ipc-lifecycle-agent-deploy
ipc-lifecycle-agent-deploy: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-lifecycle-agent-deploy: lifecycle-agent-deploy ## Deploy lifecycle-agent operator on the cluster

.PHONY: ipc-render
ipc-render: ## Render IPConfig manifest into $(IPC_WORK_DIR)/ipc.yaml
	@mkdir -p $(IPC_WORK_DIR)
	@IPC_STAGE=Idle \
	IPC_IPV4_ADDRESS="$(IPC_IPV4_ADDRESS)" \
	IPC_IPV4_MACHINE_NETWORK="$(IPC_IPV4_MACHINE_NETWORK)" \
	IPC_IPV4_GATEWAY="$(IPC_IPV4_GATEWAY)" \
	IPC_IPV6_ADDRESS="$(IPC_IPV6_ADDRESS)" \
	IPC_IPV6_MACHINE_NETWORK="$(IPC_IPV6_MACHINE_NETWORK)" \
	IPC_IPV6_GATEWAY="$(IPC_IPV6_GATEWAY)" \
	IPC_DNS_SERVERS="$(IPC_DNS_SERVERS)" \
	IPC_VLAN_ID="$(IPC_VLAN_ID)" \
	IPC_DNS_FILTER_OUT_FAMILY="$(IPC_DNS_FILTER_OUT_FAMILY)" \
	IPC_AUTO_ROLLBACK_TIMEOUT_SECONDS="$(IPC_AUTO_ROLLBACK_TIMEOUT_SECONDS)" \
	IPC_SKIP_CLUSTER_HEALTHCHECKS="$(IPC_SKIP_CLUSTER_HEALTHCHECKS)" \
	IPC_SKIP_PRE_CLUSTER_HEALTHCHECKS="$(IPC_SKIP_PRE_CLUSTER_HEALTHCHECKS)" \
	IPC_SKIP_POST_CLUSTER_HEALTHCHECKS="$(IPC_SKIP_POST_CLUSTER_HEALTHCHECKS)" \
	IPC_RECERT_IMAGE="$(IPC_RECERT_IMAGE)" \
	IPC_RECERT_PULL_SECRET="$(IPC_RECERT_PULL_SECRET)" \
	IPC_DISABLE_AUTO_ROLLBACK_INIT_MONITOR="$(IPC_DISABLE_AUTO_ROLLBACK_INIT_MONITOR)" \
	IPC_DISABLE_AUTO_ROLLBACK_IP_CONFIG_RUN="$(IPC_DISABLE_AUTO_ROLLBACK_IP_CONFIG_RUN)" \
		"$(IPC_DIR)ipc-render.sh" > $(IPC_WORK_DIR)/ipc.yaml

.PHONY: ipc-wait-ibu-idle
ipc-wait-ibu-idle: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-wait-ibu-idle: ## Wait for IBU to be idle when present (optional gating for some flows)
	@case "$(IPC_WAIT_FOR_IBU_IDLE)" in \
		1|true|yes) \
			if $(oc) get ibu upgrade >/dev/null 2>&1; then \
				echo "Waiting for IBU to be Idle (gating for IPConfig)"; \
				until $(oc) wait --timeout=30s --for=condition=Idle=true ibu upgrade >/dev/null 2>&1; do \
					echo -n .; \
					sleep 5; \
				done; \
				echo " DONE"; \
			else \
				echo "IBU CR not found on this cluster; skipping IBU gating"; \
			fi \
			;; \
		*) echo "Skipping IBU gating (IPC_WAIT_FOR_IBU_IDLE=$(IPC_WAIT_FOR_IBU_IDLE))" ;; \
	esac

.PHONY: ipc-wait-idle
ipc-wait-idle: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-wait-idle: ## Wait for IPConfig singleton to be Idle
	@echo "Waiting for IPConfig to be Idle"; \
	until $(oc) wait --timeout=30s --for=condition=Idle=true ipc ipconfig >/dev/null 2>&1; do \
		echo -n .; \
		sleep 5; \
	done; \
	echo " DONE"

.PHONY: ipc-apply
ipc-apply: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-apply: ipc-render ## Apply desired IPConfig spec (kept at stage Idle)
	$(oc) apply -f $(IPC_WORK_DIR)/ipc.yaml

.PHONY: ipc-stage-configuration
ipc-stage-configuration: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-stage-configuration: ## Request IPConfig Config stage
	$(oc) patch ipc ipconfig --type merge -p '{"spec": { "stage": "Config"}}'

.PHONY: ipc-wait-configured
ipc-wait-configured: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-wait-configured: ## Wait for IPConfig ConfigCompleted (handles transient API downtime during reboot)
	@echo "Waiting for IPConfig ConfigCompleted"; \
	deadline=$$(( $$(date +%s) + $(IPC_TIMEOUT_SECONDS) )); \
	while true; do \
		if $(oc) wait --timeout=30s --for=condition=ConfigCompleted=true ipc ipconfig >/dev/null 2>&1; then \
			echo " DONE"; \
			break; \
		fi; \
		now=$$(date +%s); \
		if [ $$now -ge $$deadline ]; then \
			echo " TIMEOUT"; \
			$(oc) get ipc ipconfig -o yaml || true; \
			exit 1; \
		fi; \
		echo -n .; \
		sleep $(IPC_WAIT_POLL_SECONDS); \
	done

.PHONY: ipc
ipc:
	@$(MAKE) ipc-wait-ibu-idle
	@$(MAKE) ipc-wait-idle
	@$(MAKE) ipc-apply
	@$(MAKE) ipc-stage-configuration
	@$(MAKE) ipc-libvirt-network-refresh
	@$(MAKE) ipc-host-dns-update
	@$(MAKE) ipc-wait-configured

.PHONY: ipc-stage-rollback
ipc-stage-rollback: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-stage-rollback: ## Request IPConfig Rollback stage
	$(oc) patch ipc ipconfig --type merge -p '{"spec": { "stage": "Rollback"}}'

.PHONY: ipc-wait-rollback
ipc-wait-rollback: SNO_KUBECONFIG=$(IPC_KUBECONFIG)
ipc-wait-rollback: ## Wait for IPConfig RollbackCompleted (handles transient API downtime during reboot)
	@echo "Waiting for IPConfig RollbackCompleted"; \
	deadline=$$(( $$(date +%s) + $(IPC_TIMEOUT_SECONDS) )); \
	while true; do \
		if $(oc) wait --timeout=30s --for=condition=RollbackCompleted=true ipc ipconfig >/dev/null 2>&1; then \
			echo " DONE"; \
			break; \
		fi; \
		now=$$(date +%s); \
		if [ $$now -ge $$deadline ]; then \
			echo " TIMEOUT"; \
			$(oc) get ipc ipconfig -o yaml || true; \
			exit 1; \
		fi; \
		echo -n .; \
		sleep $(IPC_WAIT_POLL_SECONDS); \
	done

.PHONY: ipc-rollback
ipc-rollback: ipc-lifecycle-agent-deploy ipc-wait-ibu-idle ipc-stage-rollback ipc-wait-rollback ## Roll back last IPConfig (Rollback -> wait)

.PHONY: ipc-gather
ipc-gather: ## Gather IPC/LCA debug artifacts into ARTIFACT_DIR (defaults under $(IPC_WORK_DIR))
	@ARTIFACT_DIR="$(ARTIFACT_DIR)" \
	IPC_WORK_DIR="$(IPC_WORK_DIR)" \
	IPC_KUBECONFIG="$(IPC_KUBECONFIG)" \
	IBI_VM_IP="$(IBI_VM_IP)" \
	IPC_IPV4_ADDRESS="$(IPC_IPV4_ADDRESS)" \
	IPC_IPV6_ADDRESS="$(IPC_IPV6_ADDRESS)" \
	IPC_IPV4_OLD="$(IPC_IPV4_OLD)" \
	IPC_IPV4_NEW="$(IPC_IPV4_NEW)" \
	IPC_IPV6_OLD="$(IPC_IPV6_OLD)" \
	IPC_IPV6_NEW="$(IPC_IPV6_NEW)" \
	SSH_FLAGS="$(SSH_FLAGS)" \
		bash "$(IPC_DIR)ipc-gather.sh"

.PHONY: ipc-logs-cleanup
ipc-logs-cleanup: ## Delete all IPC gather artifacts under $(IPC_LOGS_DIR)
	@set -euo pipefail; \
	root="$(ARTIFACT_DIR)"; \
	if [ ! -d "$$root" ]; then \
		echo "No IPC logs dir found at $$root (nothing to clean)"; \
		exit 0; \
	fi; \
	echo "Deleting ALL files under $$root"; \
	rm -rf "$$root"/*