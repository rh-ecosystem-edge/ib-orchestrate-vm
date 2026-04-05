#!/bin/bash

set -e # Halt on error

machineconfigs="50-performance-openshift-node-performance-profile 99-master-generated-kubelet 06-kdump-enable-master"

echo "Applying VDU profile configuration..."

# Node tuning and kdump cause downtime, apply first and wait for MCP to update
echo "Step 1: Applying performance profile and kdump configuration..."
oc apply -f ./vdu/01-node-tuning.yaml
oc apply -f ./vdu/01-kdump.yaml

# Wait for generated machineconfigs to be present
for mc in ${machineconfigs}; do
  echo "Waiting for ${mc} to be present in rendered-master MachineConfig"
  until oc get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq "${mc}"; do
    echo -n .
    sleep 10
  done
  echo " found"
done

# Wait for machineconfig to be applied (this will reboot the node)
echo "Waiting for MachineConfigPool master to update (this may take 10-20 minutes)..."
oc wait --timeout=30m --for=condition=updated=true mcp master

echo "Step 2: Creating operator namespaces..."
oc apply -f ./vdu/02-namespaces.yaml

echo "Step 3: Installing operator subscriptions..."
oc apply -f ./vdu/03-subscriptions.yaml

# Wait for subscriptions to be ready
subscriptions="
openshift-local-storage/local-storage-operator
openshift-ptp/ptp-operator-subscription
openshift-sriov-network-operator/sriov-network-operator-subscription
"

for subscription in ${subscriptions}; do
  namespace=${subscription%/*}
  name=${subscription#*/}
  echo "Waiting for subscription ${name} in namespace ${namespace}..."
  oc wait subscription --timeout=15m --for=jsonpath='{.status.state}'=AtLatestKnown -n "${namespace}" "${name}" || true
done

echo "Step 4: Applying additional configurations..."
oc apply -f ./vdu/04-configurations.yaml

echo ""
echo "VDU profile applied successfully!"
echo "Note: The cluster monitoring config and console have been configured."
echo "Additional site-specific configurations (PTP, SR-IOV, Logging) can be applied separately."
