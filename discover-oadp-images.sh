#!/bin/bash
# Script to discover images referenced in OADP FBC build
# Requires: opm, jq
#
# Usage: ./discover-oadp-images.sh <OADP_FBC_IMAGE> [OADP_VERSION]
# Example: ./discover-oadp-images.sh quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:oadp-1.6__v4.22__oadp-rhel9-operator 1.6.0

set -euo pipefail

OADP_FBC_IMAGE="${1:-}"
OADP_VERSION="${2:-}"

if [ -z "$OADP_FBC_IMAGE" ]; then
    echo "Error: OADP_FBC_IMAGE is required"
    echo "Usage: $0 <OADP_FBC_IMAGE> [OADP_VERSION]"
    echo "Example: $0 quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:oadp-1.6__v4.22__oadp-rhel9-operator 1.6.0"
    exit 1
fi

# Check for required tools
for tool in opm jq; do
    if ! command -v $tool &> /dev/null; then
        echo "Error: $tool is not installed"
        echo "Please install $tool to continue"
        echo ""
        echo "Install opm: https://docs.openshift.com/container-platform/latest/cli_reference/opm/cli-opm-install.html"
        echo "  macOS: brew install operator-framework/tap/opm"
        echo "  Linux: Download from https://github.com/operator-framework/operator-registry/releases"
        exit 1
    fi
done

echo "Discovering images from FBC: $OADP_FBC_IMAGE"
echo ""

# Render the FBC catalog
echo "Rendering FBC catalog..."
render_err=$(mktemp)
if ! CATALOG_JSON=$(opm render "$OADP_FBC_IMAGE" 2>"$render_err"); then
    echo "Error: Failed to render FBC catalog"
    cat "$render_err"
    rm -f "$render_err"
    exit 1
fi
rm -f "$render_err"

if [ -z "$CATALOG_JSON" ]; then
    echo "Error: Failed to render FBC catalog"
    exit 1
fi

# If version not specified, try to extract from tag or find latest
if [ -z "$OADP_VERSION" ]; then
    # Try to extract version from image tag (e.g., oadp-1.6__v4.22__oadp-rhel9-operator)
    if [[ "$OADP_FBC_IMAGE" =~ oadp-operator-fbc-([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        OADP_VERSION="${BASH_REMATCH[1]}"
        echo "Detected OADP version from tag: $OADP_VERSION"
    else
        # Find the latest version available in the catalog
        OADP_VERSION=$(echo "$CATALOG_JSON" | jq -r 'select(.package == "redhat-oadp-operator") | select(.schema == "olm.bundle") | .name' | sed 's/oadp-operator\.v//' | sort -V | tail -1)
        if [ -z "$OADP_VERSION" ]; then
            echo "Error: Could not determine OADP version. Please specify it as second argument."
            echo "Usage: $0 $OADP_FBC_IMAGE <version>"
            exit 1
        fi
        echo "Found OADP version in catalog: $OADP_VERSION"
    fi
fi

BUNDLE_NAME="oadp-operator.v${OADP_VERSION}"
echo "Using bundle: $BUNDLE_NAME"
echo ""

# Extract related images
echo "Extracting related images..."
IMAGES=$(echo "$CATALOG_JSON" | jq -r "select(.package == \"redhat-oadp-operator\") | select(.schema == \"olm.bundle\" and .name == \"$BUNDLE_NAME\") | .relatedImages[].image" | sort -u)

if [ -z "$IMAGES" ]; then
    echo "Error: No images found for bundle $BUNDLE_NAME"
    echo ""
    echo "Available bundles in catalog:"
    echo "$CATALOG_JSON" | jq -r 'select(.package == "redhat-oadp-operator") | select(.schema == "olm.bundle") | .name' | sort -V
    exit 1
fi

echo "Related images with digests:"
echo "============================"
echo "$IMAGES"

echo ""
echo "Related images (without digests):"
echo "=================================="
echo "$IMAGES" | sed 's/@sha256:.*//' | sort -u

echo ""
echo "Generating IDMS YAML..."
echo "======================="

cat <<EOF
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: oadp-images-mirror-set
spec:
  imageDigestMirrors:
EOF

echo "$IMAGES" | sed 's/@sha256:.*//' | sort -u | while read -r image; do
    cat <<EOF
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share
    source: $image
EOF
done

echo ""
echo "To apply the IDMS, copy the output above to a file and run:"
echo "  oc apply -f <filename>"
