# OADP Pre-GA Deployment with FBC

This guide explains how to deploy pre-GA builds of the OADP operator using File-Based Catalogs (FBC) when testing with the latest LifeCycle Agent from the main branch.

## Background

When testing LCA from the main branch, you may need a newer version of OADP that hasn't been released to the official catalog yet. Red Hat's ART (Automated Release Tooling) team publishes pre-GA builds as FBC images to a public Quay repository.

## Prerequisites

1. **Access to art-images-share** (required for pulling operator images)
   - Request access in Slack: `#forum-ocp-art`
   - Join the Rover group: https://rover.redhat.com/groups/group/art-images-share
   - Once approved, you'll receive a BitWarden invite with the pull secret
   - Test access: `podman pull --authfile <pull-secret> quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share`

2. **Tools for image discovery** (optional, only if regenerating IDMS)
   - `opm` (Operator Package Manager): https://docs.openshift.com/container-platform/latest/cli_reference/opm/cli-opm-install.html
   - `jq`: JSON processor

## Quick Start

### Standard OADP Deployment (Official Catalog)

```bash
make seed-oadp-deploy
# or
make target-oadp-deploy
```

### Pre-GA OADP Deployment (FBC)

```bash
# Set the FBC image (find latest at https://quay.io/repository/redhat-user-workloads/ocp-art-tenant/art-fbc?tab=tags)
export OADP_FBC_IMAGE=quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:oadp-1.6__v4.22__oadp-rhel9-operator

# Set the art-images-share pull secret (from BitWarden)
export OADP_ART_PULL_SECRET='{"auths":{"quay.io":{"auth":"..."}}}'

# Deploy to seed cluster
CLUSTER=seed make oadp-deploy OADP_FBC_IMAGE=$OADP_FBC_IMAGE

# Or deploy to target cluster
CLUSTER=target make oadp-deploy OADP_FBC_IMAGE=$OADP_FBC_IMAGE
```

## Finding the Latest OADP FBC Image

OADP FBC builds are published to: https://quay.io/repository/redhat-user-workloads/ocp-art-tenant/art-fbc

Tag format: `oadp-operator-fbc-<version>-<timestamp>`

Example: `oadp-1.6__v4.22__oadp-rhel9-operator`

To find a specific version or ask for a non-latest build, contact `#forum-ocp-art`.

## How FBC Deployment Works

The enhanced `oadp-deploy` target automatically handles the following when `OADP_FBC_IMAGE` is set:

### Step 1: Create CatalogSource
Creates a custom catalog pointing to the FBC image:
```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: oadp-fbc-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:oadp-1.6__v4.22__oadp-rhel9-operator
```

### Step 2: Create art-images-share Pull Secret
If `OADP_ART_PULL_SECRET` is provided, creates a secret in `openshift-marketplace` namespace for pulling images from the private art-images-share repository.

### Step 3: Apply ImageDigestMirrorSet (IDMS)
Redirects registry.redhat.io images to art-images-share since pre-GA builds aren't published to production.

The IDMS name is automatically generated based on the FBC image to ensure each FBC version gets its own IDMS:
```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: oadp-images-mirror-<hash>  # e.g., oadp-images-mirror-f68e0077
spec:
  imageDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share
    source: registry.redhat.io/oadp/oadp-rhel9-operator
  # ... more mirrors
```

When switching FBC versions:
- Old IDMS from previous FBC images are automatically cleaned up
- A new IDMS is created with a unique name based on the new FBC image
- Only one IDMS per FBC image exists at a time

**Important:** IDMS application triggers a MachineConfig update and node reboot, which can take 10-20 minutes.

### Step 4: Wait for Deployment
Waits for the OADP operator deployment to become available.

## Advanced Usage

### Discovering Images from FBC

To regenerate the IDMS with the exact images from your FBC build (requires `opm` and `jq`):

```bash
make oadp-discover-images OADP_FBC_IMAGE=quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:oadp-1.6__v4.22__oadp-rhel9-operator
```

This will:
1. Render the FBC catalog using `opm`
2. Extract the `relatedImages` from the OADP operator bundle
3. Generate IDMS YAML

You can then update `oadp-idms-template.yaml` with the generated output.

### Manual Discovery (if script fails)

```bash
# Basic command to extract images
opm render quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:oadp-1.6__v4.22__oadp-rhel9-operator | \
  jq -r 'select(.package == "redhat-oadp-operator") | select(.schema == "olm.bundle" and .name == "oadp-operator.v1.6.0") | .relatedImages[].image' | \
  sed 's/@sha256:.*//' | sort -u
```

**Example output:**
```
registry.redhat.io/oadp/oadp-mustgather-rhel9
registry.redhat.io/oadp/oadp-non-admin-rhel9
registry.redhat.io/oadp/oadp-operator-bundle
registry.redhat.io/oadp/oadp-rhel9-operator
registry.redhat.io/oadp/oadp-velero-plugin-for-aws-rhel9
registry.redhat.io/oadp/oadp-velero-plugin-for-gcp-rhel9
registry.redhat.io/oadp/oadp-velero-plugin-for-legacy-aws-rhel9
registry.redhat.io/oadp/oadp-velero-plugin-for-microsoft-azure-rhel9
registry.redhat.io/oadp/oadp-velero-plugin-rhel9
registry.redhat.io/oadp/oadp-velero-rhel9
```

### Pinning to Specific FBC SHA

For reproducibility, you can use the SHA instead of a tag:

```bash
export OADP_FBC_IMAGE=quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:42a080f7916e1fd6103b0ba644576109fa96f3aed32e2bc6040373a26535531a
```

### Using ICSP for Older OpenShift Versions

If your cluster doesn't support IDMS (< 4.13), create an ImageContentSourcePolicy instead:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: oadp-images-mirror
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share
    source: registry.redhat.io/oadp/oadp-rhel9-operator
```

## Removing OADP

To completely remove OADP (including FBC resources):

```bash
CLUSTER=seed make oadp-remove
# or
CLUSTER=target make oadp-remove
```

This removes:
- OADP subscription
- ClusterServiceVersion (CSV)
- OperatorGroup
- Namespace
- Custom CatalogSource (if FBC was used)
- All OADP ImageDigestMirrorSets (including versioned ones)
- art-images-share pull secret (unlinked from service account and deleted)

## Troubleshooting

### Missing Manifests in art-images-share

If you see "manifest unknown" errors, the images may not have been synced to art-images-share yet:
1. Check `#forum-ocp-art` in Slack
2. Request manual sync of the missing images
3. ART team will run their sync script to copy from art-images to art-images-share

### IDMS Not Applied

If the operator fails to pull images after IDMS is created:
1. Check IDMS status: `oc get imagedigestmirrorset oadp-images-mirror-set -o yaml`
2. Verify MachineConfigPool updated: `oc get mcp`
3. Check node status: `oc get nodes`
4. Review machine-config-daemon logs on affected nodes

### CatalogSource Not Ready

If the CatalogSource shows as unhealthy:
1. Check pod logs: `oc logs -n openshift-marketplace -l olm.catalogSource=oadp-fbc-catalog`
2. Verify FBC image is accessible: `oc image info $OADP_FBC_IMAGE`
3. Ensure pull secret exists if using authenticated registry

### Operator Not Installing

1. Check subscription status: `oc get subscription -n openshift-adp openshift-adp -o yaml`
2. Check install plan: `oc get installplan -n openshift-adp`
3. Review catalog operator logs: `oc logs -n openshift-marketplace deployment/catalog-operator`

## Full IBU Workflow with FBC OADP

```bash
# Set environment
export PULL_SECRET="$(jq -c . ~/openshift_pull.json)"
export BACKUP_SECRET="$(jq -c . ~/credentials.json)"
export SEED_IMAGE=quay.io/myrepo/seed:v1
export OADP_FBC_IMAGE=quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:oadp-1.6__v4.22__oadp-rhel9-operator
export OADP_ART_PULL_SECRET='<from-bitwarden>'

# Create seed with FBC OADP
make seed-vm-create wait-for-seed seed-directory-varlibcontainers
CLUSTER=seed make oadp-deploy OADP_FBC_IMAGE=$OADP_FBC_IMAGE
make seed-lifecycle-agent-deploy

# Apply vDU profile if needed
make vdu

# Create seed image
make seed-image-create SEED_IMAGE=$SEED_IMAGE

# Create target with FBC OADP
make target-vm-create wait-for-target target-directory-varlibcontainers
CLUSTER=target make oadp-deploy OADP_FBC_IMAGE=$OADP_FBC_IMAGE
make target-lifecycle-agent-deploy

# Perform upgrade
make sno-upgrade SEED_IMAGE=$SEED_IMAGE
```

## References

- FBC Documentation: https://olm.operatorframework.io/docs/reference/file-based-catalogs/
- ART FBC Quay Repository: https://quay.io/repository/redhat-user-workloads/ocp-art-tenant/art-fbc
- Rover Group: https://rover.redhat.com/groups/group/art-images-share
- Original Instructions: See `Downloads/Replacing pre-releases with FBCs.md`
