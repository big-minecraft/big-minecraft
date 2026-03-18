#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CHART_DIR="charts/bmc-chart"

echo ""
echo "=========================================="
echo "Applying MetalLB Configuration"
echo "=========================================="
echo ""

# Extract MetalLB configuration from helm template
echo "Extracting MetalLB configuration from values..."

# Use helm template to render only the MetalLB resources
helm template bmc-temp "$CHART_DIR" \
  --values "$CHART_DIR/values.yaml" \
  --values "$CHART_DIR/values.auto.yaml" \
  --values "$CHART_DIR/values.custom.yaml" \
  --show-only templates/metallb.yaml 2>/dev/null > /tmp/metallb-config.yaml

# Check if any resources were generated
if [ ! -s /tmp/metallb-config.yaml ] || ! grep -q "kind:" /tmp/metallb-config.yaml; then
  echo -e "${YELLOW}⚠${NC} MetalLB configuration not enabled or already exists"
  echo "   Skipping MetalLB resource creation"
  rm -f /tmp/metallb-config.yaml
  exit 0
fi

# Apply the configuration
echo "Applying IPAddressPool and L2Advertisement..."
if kubectl apply -f /tmp/metallb-config.yaml; then
  echo ""
  echo -e "${GREEN}✓${NC} MetalLB configuration applied successfully"
  echo ""
else
  echo ""
  echo -e "${RED}✗${NC} Failed to apply MetalLB configuration"
  echo ""
  rm -f /tmp/metallb-config.yaml
  exit 1
fi

# Clean up
rm -f /tmp/metallb-config.yaml

# Show configured IP pool
IP_POOL=$(kubectl get ipaddresspool -n metallb-system default -o jsonpath='{.spec.addresses[*]}' 2>/dev/null)
if [ -n "$IP_POOL" ]; then
  echo "Configured IP Address Pool: $IP_POOL"
  echo ""
fi
