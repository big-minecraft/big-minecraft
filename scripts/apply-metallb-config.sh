#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CHART_DIR="${CHART_DIR:-charts/bmc-chart}"
PROFILE="${PROFILE:-baremetal-metallb}"

echo ""
echo "=========================================="
echo "Applying MetalLB Configuration"
echo "=========================================="
echo ""

# Extract MetalLB configuration from helm template
echo "Extracting MetalLB configuration from values..."

# Use helm template to render only the MetalLB resources.
#
# --api-versions is REQUIRED: `helm template` does not contact the cluster, so
# .Capabilities.APIVersions is empty and the guard in templates/metallb.yaml
# renders nothing. Without this the script silently produced an empty file and
# reported success, so the IPAddressPool was never created.
RENDER_FILE=$(mktemp -t metallb-config.XXXXXX)
ERR_FILE=$(mktemp -t metallb-err.XXXXXX)
trap 'rm -f "$RENDER_FILE" "$ERR_FILE"' EXIT

# `--show-only` exits non-zero with "could not find template" when the template
# renders nothing, which is the legitimate "MetalLB disabled" case. Everything
# else is a real failure and must not be swallowed -- that swallowing is what
# hid this script doing nothing at all.
if ! helm template bmc-temp "$CHART_DIR" \
  --values "$CHART_DIR/values.yaml" \
  --values "profiles/${PROFILE}.yaml" \
  --values "$CHART_DIR/values.custom.yaml" \
  --api-versions "metallb.io/v1beta1/IPAddressPool" \
  --api-versions "metallb.io/v1beta1/L2Advertisement" \
  --show-only templates/metallb.yaml > "$RENDER_FILE" 2>"$ERR_FILE"; then

  if grep -q "could not find template" "$ERR_FILE"; then
    : > "$RENDER_FILE"   # nothing rendered; handled as "disabled" below
  else
    echo -e "${RED}✗${NC} Failed to render MetalLB configuration"
    sed 's/^/   /' "$ERR_FILE"
    exit 1
  fi
fi

# An empty render now genuinely means the resources are disabled, rather than
# meaning the capability guard silently failed.
if [ ! -s "$RENDER_FILE" ] || ! grep -q "kind:" "$RENDER_FILE"; then
  echo -e "${YELLOW}⚠${NC} MetalLB resources are disabled"
  echo "   (global.metallb.installResources is false in this profile)"
  echo "   Skipping MetalLB resource creation"
  exit 0
fi

# Apply the configuration
echo "Applying IPAddressPool and L2Advertisement..."
if kubectl apply -f "$RENDER_FILE"; then
  echo ""
  echo -e "${GREEN}✓${NC} MetalLB configuration applied successfully"
  echo ""
else
  echo ""
  echo -e "${RED}✗${NC} Failed to apply MetalLB configuration"
  echo ""
  exit 1
fi

# Show configured IP pool
IP_POOL=$(kubectl get ipaddresspool -n metallb-system default -o jsonpath='{.spec.addresses[*]}' 2>/dev/null || true)
if [ -n "$IP_POOL" ]; then
  echo "Configured IP Address Pool: $IP_POOL"
  echo ""
fi
