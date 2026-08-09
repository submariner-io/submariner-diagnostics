# Deployment Type Detection

How to detect whether Submariner is deployed via ACM (ACM-Managed) or standalone.

## Why This Matters

**CRITICAL:** The deployment type determines where configuration changes must be made.

- **ACM-Managed:** Changes MUST be made to SubmarinerConfig CR on ACM hub cluster
  - DO NOT modify Submariner CR directly (ACM addon will override it)
- **Standalone:** Changes made to Submariner CR in each managed cluster

## Data Sources

Check for submariner-addon pod in gather output:

- `cluster1/gather/*/submariner-addon*.log` or `submariner-addon*.yaml`
- Collected automatically by `subctl gather`

## Detection Logic

### Check for submariner-addon pod in gather output

**The `submariner-addon` pod is the definitive indicator:**

- Deployed by ACM Hub to managed clusters
- Only exists in ACM-managed deployments  
- Collected automatically by `subctl gather`

**Detection:**
- Look for files matching `*submariner-addon*` in `cluster1/gather/<cluster-name>/`
- If found → **ACM-Managed**
- If not found → **Standalone**

**Why this is definitive:** The submariner-addon pod only exists in ACM-managed clusters.
This is more reliable than checking for ManagedClusterAddOn (which exists on ACM Hub, not on managed clusters).

## Deployment Type Characteristics

### ACM-Managed Deployment

**Indicators:**
- `submariner-addon` pod running in `submariner-operator` namespace
- Submariner CR has `ownerReferences` pointing to `AppliedManifestWork`
- Submariner CR `managedFields` shows `manager: work-agent`

**Configuration Requirements:**
- All changes must be made to SubmarinerConfig CR on ACM hub cluster
- DO NOT modify Submariner CR directly (will be overridden by ACM addon)
- ACM addon controller propagates changes to managed clusters

### Standalone Submariner Deployment

**Indicators:**
- NO `submariner-addon` pod
- Submariner CR managed by `submariner-operator`
- No ACM-related resources

**Configuration Requirements:**
- Changes made to Submariner CR in each managed cluster
- Direct kubectl patch/edit of Submariner CR
- No ACM hub cluster involvement

## Example Detection

### Example 1: ACM-Managed

File: `cluster1/acm-addons.txt`

```yaml
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: submariner
  namespace: cluster1
```

File: `cluster1/submarinerconfig.yaml`

```yaml
apiVersion: submarineraddon.open-cluster-management.io/v1alpha1
kind: SubmarinerConfig
metadata:
  name: submariner
  namespace: cluster1
spec:
  cableDriver: libreswan
```

→ **Deployment Type: ACM-Managed**

### Example 2: Standalone

File: `cluster1/acm-addons.txt`

```text
No resources found
```

File: `cluster1/submarinerconfig.yaml`

```text
No resources found
```

→ **Deployment Type: Standalone Submariner**

## Providing Deployment-Specific Instructions

### ACM-Managed Example

```bash
# INCORRECT (will be overridden):
kubectl patch submariner -n submariner-operator submariner \
  --type merge \
  -p '{"spec": {"ceIPSecForceUDPEncaps": true}}'

# CORRECT (on ACM hub cluster):
kubectl patch submarinerconfig -n <managed-cluster-namespace> <config-name> \
  --type merge \
  -p '{"spec": {"ceIPSecForceUDPEncaps": true}}'

# ACM will propagate changes automatically to managed clusters
```

### Standalone Example

```bash
# CORRECT (on each managed cluster):
kubectl patch submariner -n submariner-operator submariner \
  --type merge \
  -p '{"spec": {"ceIPSecForceUDPEncaps": true}}'

kubectl delete pods -n submariner-operator -l app=submariner-gateway
```

## Important Notes

- Always detect deployment type before providing configuration instructions
- Never give generic instructions that could apply to both
- ACM-managed deployments require hub cluster access
- Standalone deployments require access to each managed cluster
