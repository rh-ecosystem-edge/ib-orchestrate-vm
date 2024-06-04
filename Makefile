# Disable built-in rules
MAKEFLAGS += --no-builtin-rules

IMAGE_BASED_DIR = .
SNO_DIR = ./bip-orchestrate-vm

-include .config-override

# Define precache mode (partition or directory)
PRECACHE_MODE ?= partition

# Set to Disabled to disable IBU rollback (case sensitive)
IBU_ROLLBACK ?= Enabled

include network.env

default: help

.PHONY: checkenv
checkenv:
ifndef PULL_SECRET
	$(error PULL_SECRET must be defined)
endif

AGENT_CONFIG_TEMPLATE = agent-config-template.yaml
ifdef DHCP
    AGENT_CONFIG_TEMPLATE = agent-config-template-dhcp.yaml
endif

VIRSH_CONNECT ?= qemu:///system
virsh = sudo virsh --connect=$(VIRSH_CONNECT)

SEED_VM_NAME  ?= seed
SEED_DOMAIN ?= $(NET_SEED_DOMAIN)
SEED_VM_IP  ?= 192.168.126.10
SEED_VERSION ?= 4.15.2
SEED_MAC ?= 52:54:00:ee:42:e1

TARGET_VM_NAME ?= target
TARGET_DOMAIN ?= $(NET_TARGET_DOMAIN)
TARGET_VM_IP  ?= 192.168.127.99
TARGET_VERSION ?= 4.14.14
TARGET_MAC ?= 52:54:00:fa:ba:da

UPGRADE_TIMEOUT ?= 30m

LIBVIRT_IMAGE_PATH := $(or ${LIBVIRT_IMAGE_PATH},/var/lib/libvirt/images)

CPU_CORE ?= 16
RAM_MB ?= 32768
DISK_GB ?= 140
LCA_IMAGE ?= quay.io/openshift-kni/lifecycle-agent-operator:latest
LCA_GIT_REPO ?= https://github.com/openshift-kni/lifecycle-agent
LCA_GIT_BRANCH ?= main
RELEASE_ARCH ?= x86_64
DEFAULT_RELEASE_IMAGE ?= quay.io/openshift-release-dev/ocp-release:$(RELEASE_VERSION)-$(RELEASE_ARCH)
SEED_RELEASE_IMAGE ?= $(DEFAULT_RELEASE_IMAGE)
TARGET_RELEASE_IMAGE ?= $(DEFAULT_RELEASE_IMAGE)
RECERT_IMAGE ?= quay.io/edge-infrastructure/recert:v0

SSH_KEY_DIR = $(SNO_DIR)/ssh-key
SSH_KEY_PUB_PATH = $(SSH_KEY_DIR)/key.pub
SSH_KEY_PRIV_PATH = $(SSH_KEY_DIR)/key
# SSH_KEY can be supplied by user
SSH_KEY ?= SSH_KEY_PUB_PATH

SSH_FLAGS = -o IdentityFile=$(SSH_KEY_PRIV_PATH) \
 			-o UserKnownHostsFile=/dev/null \
 			-o StrictHostKeyChecking=no

HOST_IP ?= $(SEED_VM_IP)
SSH_HOST = core@$(HOST_IP)

# Default cluster is seed cluster, you can change easily by setting CLUSTER=target on the command line
CLUSTER ?= $(SEED_VM_NAME)
SNO_KUBECONFIG ?= $(SNO_DIR)/workdir-$(CLUSTER)/auth/kubeconfig
oc = oc --kubeconfig $(SNO_KUBECONFIG)

$(SSH_KEY_PRIV_PATH):
	@echo "No private key $@ found, generating a private-public pair"
	@mkdir -p $(SSH_KEY_DIR)
	# -N "" means no password
	ssh-keygen -f $@ -N ""
	chmod 400 $@

$(SSH_KEY_PUB_PATH): $(SSH_KEY_PRIV_PATH)
	@if [ ! -e $(SSH_KEY_PUB_PATH) ]; then \
		echo "SSH private key found, but no public key found on $(SSH_KEY_PUB_PATH)"; \
		echo "Generating public SSH key using the private key $(SSH_KEY_PRIV_PATH) as a source"; \
		ssh-keygen -f $(SSH_KEY_PRIV_PATH) -q -y > $(SSH_KEY_PUB_PATH); \
	fi

.PHONY: bip-orchestrate-vm
bip-orchestrate-vm:
	@if [ -d $@ ]; then \
		git -C $@ pull ;\
	else \
		git clone https://github.com/rh-ecosystem-edge/bip-orchestrate-vm ;\
	fi

.PHONY: lifecycle-agent
lifecycle-agent:
	@if [ -d $@ ]; then \
		git -C $@ pull ;\
	else \
		git clone $(LCA_GIT_REPO) --branch $(LCA_GIT_BRANCH) lifecycle-agent;\
	fi

## VM provision in a single step
.PHONY: seed
seed: seed-vm-create wait-for-seed seed-cluster-prepare ## Provision and prepare seed VM

.PHONY: target
target: target-vm-create wait-for-target target-cluster-prepare ## Provision and prepare target VM

## Seed image management
# make seed-image-create SEED_IMAGE=quay.io/whatever/ostmagic:seed
.PHONY: seed-image-create
seed-image-create: CLUSTER=$(SEED_VM_NAME)
seed-image-create: trigger-seed-image-create wait-seed-image-create ## Create seed image

.PHONY: trigger-seed-image-create
trigger-seed-image-create: CLUSTER=$(SEED_VM_NAME)
trigger-seed-image-create:
	@echo "Triggering seed image creation"
	@< seedgenerator.yaml \
		SEED_AUTH=$(shell echo '$(BACKUP_SECRET)' | base64 -w0) \
		SEED_IMAGE=$(SEED_IMAGE) \
		RECERT_IMAGE=$(RECERT_IMAGE) \
		envsubst | \
		  $(oc) apply -f -

.PHONY: wait-seed-image-create
wait-seed-image-create: CLUSTER=$(SEED_VM_NAME)
wait-seed-image-create:
	@echo "Waiting for seed image to be completed"; \
	until $(oc) wait --timeout 30m seedgenerator seedimage --for=condition=SeedGenCompleted=true; do \
		echo "Cluster not yet available. Trying again";\
		sleep 15; \
	done; echo

.PHONY: sno-upgrade
sno-upgrade: CLUSTER=$(TARGET_VM_NAME)
sno-upgrade: lca-stage-idle lca-stage-prep lca-wait-for-prep lca-stage-upgrade lca-wait-for-upgrade ## Upgrade using seed image		make sno-upgrade SEED_IMAGE=quay.io/whatever/ostmagic:seed SEED_VERSION=4.13.5
	@echo "Seed image restoration process complete"

## Seed VM management

.PHONY: seed-vm-create
seed-vm-create: VM_NAME=$(SEED_VM_NAME)
seed-vm-create: HOST_IP=$(SEED_VM_IP)
seed-vm-create: RELEASE_VERSION=$(SEED_VERSION)
seed-vm-create: RELEASE_IMAGE=$(SEED_RELEASE_IMAGE)
seed-vm-create: MAC_ADDRESS=$(SEED_MAC)
seed-vm-create: BASE_DOMAIN=$(SEED_DOMAIN)
seed-vm-create: NET_NAME=$(NET_SEED_NAME)
seed-vm-create: NET_BRIDGE_NAME=$(NET_SEED_BRIDGE_NAME)
seed-vm-create: NET_MAC=$(NET_SEED_MAC)
seed-vm-create: NET_UUID=$(NET_SEED_UUID)
seed-vm-create: MACHINE_NETWORK=$(NET_SEED_NETWORK)
seed-vm-create: start-iso-abi ## Install seed SNO cluster

.PHONY: wait-for-seed
wait-for-seed: CLUSTER=$(SEED_VM_NAME)
wait-for-seed: wait-for-install-complete ## Wait for seed cluster to complete installation

.PHONY: seed-ssh
seed-ssh: HOST_IP=$(SEED_VM_IP)
seed-ssh: ssh ## ssh into seed VM

.PHONY: seed-vm-backup
seed-vm-backup: VM_NAME=$(SEED_VM_NAME)
seed-vm-backup: VERSION=$(SEED_VERSION)
seed-vm-backup: vm-backup ## Make a copy of seed VM disk image (qcow2 file)

.PHONY: seed-vm-restore
seed-vm-restore: VM_NAME=$(SEED_VM_NAME)
seed-vm-restore: VERSION=$(SEED_VERSION)
seed-vm-restore: vm-restore ## Restore a copy of seed VM disk image (qcow2 file)

.PHONY: seed-vm-recert
seed-vm-recert: VM_NAME=$(SEED_VM_NAME)
seed-vm-recert: vm-recert ## Run recert to extend certificates in seed VM

.PHONY: seed-vm-remove
seed-vm-remove: VM_NAME=$(SEED_VM_NAME)
seed-vm-remove: vm-remove ## Remove the seed VM and the storage associated with it

.PHONY: seed-lifecycle-agent-deploy
seed-lifecycle-agent-deploy: CLUSTER=$(SEED_VM_NAME)
seed-lifecycle-agent-deploy: lifecycle-agent-deploy

.PHONY: seed-cluster-prepare
seed-cluster-prepare: seed-directory-varlibcontainers seed-lifecycle-agent-deploy ## Prepare seed VM cluster

.PHONY: seed-directory-varlibcontainers
seed-directory-varlibcontainers: CLUSTER=$(SEED_VM_NAME)
seed-directory-varlibcontainers: directory-varlibcontainers

.PHONY: generate-dnsmasq-site-policy-section.sh
generate-dnsmasq-site-policy-section.sh:
	curl -sOL https://raw.githubusercontent.com/$(shell echo $(LCA_GIT_REPO) | awk -F 'github.com/' '{print $$NF}')/$(LCA_GIT_BRANCH)/hack/generate-dnsmasq-site-policy-section.sh
	chmod +x $@

.PHONY: dnsmasq-workaround
# dnsmasq workaround until https://github.com/openshift/assisted-service/pull/5658 is in assisted
dnsmasq-workaround: generate-dnsmasq-site-policy-section.sh
	./generate-dnsmasq-site-policy-section.sh --name $(SEED_VM_NAME) --domain $(NET_SEED_DOMAIN) --ip $(SEED_VM_IP) --mc | $(oc) apply -f -

.PHONY: vdu
vdu: ## Apply VDU profile to seed VM
	KUBECONFIG=$(SNO_KUBECONFIG) \
		$(IMAGE_BASED_DIR)/vdu-profile.sh

## Target VM management
.PHONY: target-vm-create
target-vm-create: VM_NAME=$(TARGET_VM_NAME)
target-vm-create: HOST_IP=$(TARGET_VM_IP)
target-vm-create: RELEASE_VERSION=$(TARGET_VERSION)
target-vm-create: RELEASE_IMAGE=$(TARGET_RELEASE_IMAGE)
target-vm-create: MAC_ADDRESS=$(TARGET_MAC)
target-vm-create: BASE_DOMAIN=$(TARGET_DOMAIN)
target-vm-create: NET_NAME=$(NET_TARGET_NAME)
target-vm-create: NET_BRIDGE_NAME=$(NET_TARGET_BRIDGE_NAME)
target-vm-create: NET_MAC=$(NET_TARGET_MAC)
target-vm-create: NET_UUID=$(NET_TARGET_UUID)
target-vm-create: MACHINE_NETWORK=$(NET_TARGET_NETWORK)
target-vm-create: start-iso-abi ## Install target SNO cluster

.PHONY: wait-for-target
wait-for-target: CLUSTER=$(TARGET_VM_NAME)
wait-for-target: wait-for-install-complete ## Wait for target cluster to complete installation

.PHONY: target-ssh
target-ssh: HOST_IP=$(TARGET_VM_IP)
target-ssh: ssh ## ssh into target VM

.PHONY: target-vm-backup
target-vm-backup: VM_NAME=$(TARGET_VM_NAME)
target-vm-backup: VERSION=$(TARGET_VERSION)
target-vm-backup: vm-backup ## Make a copy of target VM disk image (qcow2 file)

.PHONY: target-vm-recert
target-vm-recert: VM_NAME=$(TARGET_VM_NAME)
target-vm-recert: vm-recert ## Run recert to extend certificates in target VM

.PHONY: target-vm-restore
target-vm-restore: VM_NAME=$(TARGET_VM_NAME)
target-vm-restore: VERSION=$(TARGET_VERSION)
target-vm-restore: vm-restore ## Restore a copy of target VM disk image (qcow2 file)

.PHONY: target-vm-remove
target-vm-remove: VM_NAME=$(TARGET_VM_NAME)
target-vm-remove: vm-remove ## Remove the target VM and the storage associated with it

.PHONY: target-lifecycle-agent-deploy
target-lifecycle-agent-deploy: CLUSTER=$(TARGET_VM_NAME)
target-lifecycle-agent-deploy: lifecycle-agent-deploy

.PHONY: target-cluster-prepare
target-cluster-prepare: target-directory-varlibcontainers oadp-deploy target-lifecycle-agent-deploy ## Prepare target VM cluster

.PHONY: target-directory-varlibcontainers
target-directory-varlibcontainers: CLUSTER=$(TARGET_VM_NAME)
target-directory-varlibcontainers: directory-varlibcontainers

.PHONY: oadp-deploy
oadp-deploy: CLUSTER=$(TARGET_VM_NAME)
oadp-deploy:
	$(oc) apply -f oadp-operator.yaml
	@echo "Waiting for deployment openshift-adp-controller-manager to be available"; \
	until $(oc) wait deployment -n openshift-adp openshift-adp-controller-manager --for=condition=available=true; do \
		echo -n .;\
		sleep 5; \
	done; echo

## Extra
.PHONY: lca-logs
lca-logs: CLUSTER=$(TARGET_VM_NAME)
lca-logs: ## Tail through LifeCycle Agent logs	make lca-logs CLUSTER=seed
	$(oc) logs -f -c manager -n openshift-lifecycle-agent -l app.kubernetes.io/component=lifecycle-agent

start-iso-abi: checkenv bip-orchestrate-vm check-old-net network
	if [[ "$(PRECACHE_MODE)" == "partition" ]]; then \
		cp 98_varlibcontainers_as_partition.yaml $(SNO_DIR)/manifests; \
	fi
	@< $(AGENT_CONFIG_TEMPLATE) \
		VM_NAME=$(VM_NAME) \
		HOST_IP=$(HOST_IP) \
		HOST_MAC=$(MAC_ADDRESS) \
		HOST_ROUTE=$(shell $(virsh) net-dumpxml $(NET_NAME) | grep '<ip ' | xargs -n1 | grep address | cut -d = -f 2) \
		envsubst > $(shell pwd)/agent-config-$(VM_NAME).yaml
	make -C $(SNO_DIR) $@ \
		VM_NAME=$(VM_NAME) \
		HOST_IP=$(HOST_IP) \
		MACHINE_NETWORK=$(MACHINE_NETWORK) \
		CLUSTER_NAME=$(VM_NAME) \
		HOST_MAC=$(MAC_ADDRESS) \
		AGENT_CONFIG=$(shell pwd)/agent-config-$(VM_NAME).yaml \
		INSTALLER_WORKDIR=workdir-$(VM_NAME) \
		RELEASE_VERSION=$(RELEASE_VERSION) \
		RELEASE_IMAGE=$(RELEASE_IMAGE) \
		CPU_CORE=$(CPU_CORE) \
		DISK_GB=$(DISK_GB) \
		RELEASE_ARCH=$(RELEASE_ARCH) \
		RAM_MB=$(RAM_MB) \
		BASE_DOMAIN=$(BASE_DOMAIN) \
		NET_NAME=$(NET_NAME) \
		NET_BRIDGE_NAME=$(NET_BRIDGE_NAME) \
		NET_UUID=$(NET_UUID) \
		NET_MAC=$(NET_MAC)
	if [[ "$(PRECACHE_MODE)" == "partition" ]]; then \
		rm $(SNO_DIR)/manifests/98_varlibcontainers_as_partition.yaml; \
	fi

# Network used for the seed VM
seed-network: NET_NAME=$(NET_SEED_NAME)
seed-network: NET_UUID=$(NET_SEED_UUID)
seed-network: NET_BRIDGE_NAME=$(NET_SEED_BRIDGE_NAME)
seed-network: NET_MAC=$(NET_SEED_MAC)
seed-network: MACHINE_NETWORK=$(NET_SEED_NETWORK)
seed-network: BASE_DOMAIN=$(NET_SEED_DOMAIN)
seed-network: network

# Network used for the targets (target and ibi)
target-network: NET_NAME=$(NET_TARGET_NAME)
target-network: NET_UUID=$(NET_TARGET_UUID)
target-network: NET_BRIDGE_NAME=$(NET_TARGET_BRIDGE_NAME)
target-network: NET_MAC=$(NET_TARGET_MAC)
target-network: MACHINE_NETWORK=$(NET_TARGET_NETWORK)
target-network: BASE_DOMAIN=$(NET_TARGET_DOMAIN)
target-network: network

# Call network creation in bip-orchestrate-vm repo
network: check-old-net
	make -C $(SNO_DIR) $@ \
		NET_NAME=$(NET_NAME) \
		NET_UUID=$(NET_UUID) \
		NET_BRIDGE_NAME=$(NET_BRIDGE_NAME) \
		NET_MAC=$(NET_MAC) \
		MACHINE_NETWORK=$(MACHINE_NETWORK) \
		BASE_DOMAIN=$(BASE_DOMAIN)

.PHONY: wait-for-install-complete
wait-for-install-complete:
	echo "Waiting for installation to complete"
	@until [ "$$($(oc) get clusterversion -o jsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}')" == "True" ]; do \
			echo -n .; sleep 10; \
	done; \
	make -C $(SNO_DIR) abi-wait-complete INSTALLER_WORKDIR=workdir-$(CLUSTER); \
	echo " DONE"

.PHONY: credentials/backup-secret.json
credentials/backup-secret.json:
	@test '$(BACKUP_SECRET)' || { echo "BACKUP_SECRET must be defined"; exit 1; }
	@mkdir -p credentials
	@echo '$(BACKUP_SECRET)' > credentials/backup-secret.json

.PHONY: credentials/pull-secret.json
credentials/pull-secret.json:
	@test '$(PULL_SECRET)' || { echo "PULL_SECRET must be defined"; exit 1; }
	@mkdir -p credentials
	@echo '$(PULL_SECRET)' > credentials/pull-secret.json

.PHONY: lifecycle-agent-deploy
lifecycle-agent-deploy: lifecycle-agent
	KUBECONFIG=../$(SNO_KUBECONFIG) \
	IMG=$(LCA_IMAGE) \
		make -C lifecycle-agent install deploy
	@echo "Waiting for deployment lifecycle-agent-controller-manager to be available"; \
	until $(oc) wait deployment -n openshift-lifecycle-agent lifecycle-agent-controller-manager --for=condition=available=true; do \
		echo -n .;\
		sleep 5; \
	done; echo

.PHONY: lca-stage-idle
lca-stage-idle: CLUSTER=$(TARGET_VM_NAME)
lca-stage-idle: credentials/backup-secret.json
	# DISABLE_IBU_ROLLBACK
	$(oc) create secret generic seed-pull-secret -n openshift-lifecycle-agent --from-file=.dockerconfigjson=credentials/backup-secret.json \
		--type=kubernetes.io/dockerconfigjson --dry-run=client -oyaml \
		| $(oc) apply -f -
	SEED_VERSION=$(SEED_VERSION) SEED_IMAGE=$(SEED_IMAGE) IBU_ROLLBACK=$(IBU_ROLLBACK) envsubst < imagebasedupgrade.yaml | $(oc) apply -f -

.PHONY: lca-stage-prep
lca-stage-prep: CLUSTER=$(TARGET_VM_NAME)
lca-stage-prep:
	$(oc) patch --type=json ibu upgrade --type merge -p '{"spec": { "stage": "Prep"}}'

.PHONY: lca-wait-for-prep
lca-wait-for-prep: CLUSTER=$(TARGET_VM_NAME)
lca-wait-for-prep:
	$(oc) wait --timeout=30m --for=condition=PrepCompleted=true ibu upgrade

.PHONY: lca-stage-upgrade
lca-stage-upgrade: CLUSTER=$(TARGET_VM_NAME)
lca-stage-upgrade:
	$(oc) patch --type=json ibu upgrade --type merge -p '{"spec": { "stage": "Upgrade"}}'

.PHONY: lca-wait-for-upgrade
lca-wait-for-upgrade: CLUSTER=$(TARGET_VM_NAME)
lca-wait-for-upgrade:
	$(oc) wait --timeout=$(UPGRADE_TIMEOUT) --for=condition=UpgradeCompleted=true ibu upgrade

.PHONY: ssh
ssh: $(SSH_KEY_PRIV_PATH)
	ssh $(SSH_FLAGS) $(SSH_HOST)

.PHONY: directory-varlibcontainers
directory-varlibcontainers:
	if [[ "$(PRECACHE_MODE)" == "directory" ]]; then \
		$(oc) apply -f ostree-var-lib-containers-machineconfig.yaml; \
		echo "Waiting for 98-var-lib-containers to be present in running rendered-master MachineConfig"; \
		until $(oc) get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq 98-var-lib-containers; do \
			echo -n .;\
			sleep 30; \
		done; echo; \
		$(oc) wait --timeout=20m --for=condition=updated=true mcp master; \
	fi

.PHONY: vm-backup
vm-backup:
	scp $(SSH_FLAGS) recert_script.sh core@$(VM_NAME):/var/tmp
	ssh $(SSH_FLAGS) core@$(VM_NAME) sudo RECERT_IMAGE=$(RECERT_IMAGE) /var/tmp/recert_script.sh backup
	$(virsh) shutdown $(VM_NAME)
	@until $(virsh) domstate $(VM_NAME) | grep -qx 'shut off' ; do echo -n . ; sleep 5; done; echo
	sudo cp "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME).qcow2" "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME)-$(VERSION)-$(PRECACHE_MODE)-backup.qcow2"
	$(virsh) start $(VM_NAME)

.PHONY: vm-restore
vm-restore:
	-$(virsh) destroy $(VM_NAME)
	@until $(virsh) domstate $(VM_NAME) | grep -qx 'shut off' ; do echo -n . ; sleep 5; done; echo
	sudo cp "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME)-$(VERSION)-$(PRECACHE_MODE)-backup.qcow2" "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME).qcow2"
	$(virsh) start $(VM_NAME)

.PHONY: vm-recert
vm-recert: CLUSTER=$(VM_NAME)
vm-recert:
	echo "Waiting for $(VM_NAME) to start"
	@until ssh $(SSH_FLAGS) core@$(VM_NAME) true; do sleep 5; echo -n .; done
	ssh $(SSH_FLAGS) core@$(VM_NAME) sudo RECERT_IMAGE=$(RECERT_IMAGE) /var/tmp/recert_script.sh recert
	echo "Waiting for openshift to start"
	@until [ "$$($(oc) get clusterversion -o jsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}')" == "True" ]; do \
			echo -n .; sleep 10; \
	done; \
	echo " DONE"

.PHONY: vm-remove
vm-remove:
	echo "Destroying and unregistering $(VM_NAME)"
	-$(virsh) destroy $(VM_NAME)
	-$(virsh) undefine $(VM_NAME) --remove-all-storage

# Delete check-old-net and clean-old-net targets after some time, when everyone has already switched to the new networks
.PHONY: check-old-net
check-old-net:
	@if $(virsh) net-dumpxml test-net 2> /dev/null | grep -q "<uuid>a29bce40-ce15-43c8-9142-fd0a3cc37f9a</uuid>"; then \
		echo ERROR; \
		echo Old test-net network found; \
		echo; \
		echo In order to work with the new network names you need to delete the existing VMs attached to that network, and then the network:; \
		echo You can do this by running; \
		echo "   make clean-old-net"; \
		echo; \
		echo; \
		false; \
	fi

.PHONY: clean-old-net
clean-old-net: seed-vm-remove target-vm-remove
	make -C $(SNO_DIR) destroy-libvirt-net NET_NAME=test-net

.PHONY: clean-libvirt
clean-libvirt:
	-for host in $(SEED_VM_NAME) $(TARGET_VM_NAME) $(IBI_VM_NAME); do \
		$(virsh) destroy $$host; \
		$(virsh) undefine --remove-all-storage $$host; \
	done
	-for net in test-net $(NET_SEED_NAME) $(NET_TARGET_NAME); do \
		make -C $(SNO_DIR) destroy-libvirt-net NET_NAME=$$net; \
	done

.PHONY: clean-all
clean-all: clean-libvirt
	-rm -fr $(SNO_DIR) lifecycle-agent ibi-iso-work-dir bin ibi-certs kubeconfig.ibi credentials

.PHONY: help
help:
	@gawk -vG=$$(tput setaf 6) -vR=$$(tput sgr0) ' \
		match($$0,"^(([^:]*[^ :]) *:)?([^#]*)## (.*)",a) { \
			if (a[2]!="") {printf "%s%-30s%s %s\n",G,a[2],R,a[4];next}\
			if (a[3]=="") {print a[4];next}\
			printf "\n%-30s %s\n","",a[4]\
		}\
	' $(MAKEFILE_LIST)

include Makefile.ibi
