#!/bin/bash
set -euo pipefail

NAMESPACE="openshift-machine-api"

echo "==> Detecting worker MachineSet..."
WORKER_MS=$(oc get machineset -n "$NAMESPACE" \
  -l 'machine.openshift.io/cluster-api-machine-role=worker' \
  -o jsonpath='{.items[0].metadata.name}')

if [ -z "$WORKER_MS" ]; then
  echo "ERROR: Could not find any worker MachineSet"
  exit 1
fi
echo "    Using: $WORKER_MS"

echo "==> Extracting cluster info and image spec..."
MS_JSON=$(oc get machineset "$WORKER_MS" -n "$NAMESPACE" -o json)

CLUSTER_ID=$(echo "$MS_JSON"      | jq -r '.metadata.labels["machine.openshift.io/cluster-api-cluster"]')
LOCATION=$(echo "$MS_JSON"        | jq -r '.spec.template.spec.providerSpec.value.location')
VM_SIZE=$(echo "$MS_JSON"         | jq -r '.spec.template.spec.providerSpec.value.vmSize')
VNET=$(echo "$MS_JSON"            | jq -r '.spec.template.spec.providerSpec.value.vnet')
SUBNET=$(echo "$MS_JSON"          | jq -r '.spec.template.spec.providerSpec.value.subnet')
RG=$(echo "$MS_JSON"              | jq -r '.spec.template.spec.providerSpec.value.resourceGroup')
NET_RG=$(echo "$MS_JSON"          | jq -r '.spec.template.spec.providerSpec.value.networkResourceGroup')
IMG_OFFER=$(echo "$MS_JSON"       | jq -r '.spec.template.spec.providerSpec.value.image.offer')
IMG_PUBLISHER=$(echo "$MS_JSON"   | jq -r '.spec.template.spec.providerSpec.value.image.publisher')
IMG_SKU=$(echo "$MS_JSON"         | jq -r '.spec.template.spec.providerSpec.value.image.sku')
IMG_VERSION=$(echo "$MS_JSON"     | jq -r '.spec.template.spec.providerSpec.value.image.version')
IMG_TYPE=$(echo "$MS_JSON"        | jq -r '.spec.template.spec.providerSpec.value.image.type')
IMG_RESOURCE_ID=$(echo "$MS_JSON" | jq -r '.spec.template.spec.providerSpec.value.image.resourceID')
OS_DISK_SIZE=$(echo "$MS_JSON"    | jq -r '.spec.template.spec.providerSpec.value.osDisk.diskSizeGB')
OS_DISK_STORAGE=$(echo "$MS_JSON" | jq -r '.spec.template.spec.providerSpec.value.osDisk.managedDisk.storageAccountType')

MISSING=""
for varname in CLUSTER_ID LOCATION VM_SIZE VNET SUBNET RG NET_RG; do
  val=$(eval echo "\$$varname")
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    MISSING="$MISSING $varname"
  fi
done
if [ -n "$MISSING" ]; then
  echo "ERROR: Could not extract required fields from MachineSet '$WORKER_MS':$MISSING"
  exit 1
fi

if [ -z "$OS_DISK_SIZE" ] || [ "$OS_DISK_SIZE" = "null" ]; then
  OS_DISK_SIZE=128
fi
if [ -z "$OS_DISK_STORAGE" ] || [ "$OS_DISK_STORAGE" = "null" ]; then
  OS_DISK_STORAGE="Premium_LRS"
fi

GW_MS_NAME="${CLUSTER_ID}-submariner-gw"

echo "    ClusterID:        $CLUSTER_ID"
echo "    Location:         $LOCATION"
echo "    VMSize:           $VM_SIZE"
echo "    Image type:       $IMG_TYPE"
echo "    Image offer:      $IMG_OFFER / $IMG_PUBLISHER / $IMG_SKU / $IMG_VERSION"
echo "    Image resourceID: $IMG_RESOURCE_ID"
echo "    OsDisk:           ${OS_DISK_SIZE}GB / $OS_DISK_STORAGE"
echo "    GW MachineSet:    $GW_MS_NAME"

if oc get machineset "$GW_MS_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "==> Gateway MachineSet '$GW_MS_NAME' already exists. Skipping creation."
else
  echo "==> Creating gateway MachineSet..."
  oc apply -f - <<EOF
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: ${GW_MS_NAME}
  namespace: ${NAMESPACE}
  labels:
    machine.openshift.io/cluster-api-cluster: "${CLUSTER_ID}"
    submariner.io/gateway: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: "${CLUSTER_ID}"
      machine.openshift.io/cluster-api-machineset: "${GW_MS_NAME}"
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: "${CLUSTER_ID}"
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: "${GW_MS_NAME}"
        submariner.io/gateway: "true"
    spec:
      metadata:
        labels:
          submariner.io/gateway: "true"
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AzureMachineProviderSpec
          location: "${LOCATION}"
          vmSize: "${VM_SIZE}"
          vnet: "${VNET}"
          subnet: "${SUBNET}"
          resourceGroup: "${RG}"
          networkResourceGroup: "${NET_RG}"
          publicIP: true
          image:
            offer: "${IMG_OFFER}"
            publisher: "${IMG_PUBLISHER}"
            resourceID: "${IMG_RESOURCE_ID}"
            sku: "${IMG_SKU}"
            type: "${IMG_TYPE}"
            version: "${IMG_VERSION}"
          osDisk:
            diskSizeGB: ${OS_DISK_SIZE}
            managedDisk:
              storageAccountType: "${OS_DISK_STORAGE}"
            osType: Linux
EOF
  echo "==> MachineSet created."
fi

echo ""
echo "==> Waiting for gateway node to become Ready (max 10 min)..."
READY="0"
for i in $(seq 1 30); do
  READY=$(oc get machineset "$GW_MS_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY}" = "1" ]; then
    echo "    Gateway node is Ready."
    break
  fi
  echo "    Waiting... ($i/30)"
  sleep 20
done
if [ "${READY}" != "1" ]; then
  echo "ERROR: MachineSet '$GW_MS_NAME' in namespace '$NAMESPACE' did not become Ready within the timeout"
  exit 1
fi

echo ""
echo "==> Gateway nodes:"
oc get nodes -l submariner.io/gateway=true 2>/dev/null || \
  echo "    None yet — node still provisioning"

echo ""
echo "==> Done. Run subctl join with --label-gateway=false:"
echo "    subctl join <broker-info> --label-gateway=false --kubeconfig \$KUBECONFIG"
