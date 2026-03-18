#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

VALUES_FILE="charts/bmc-chart/values.custom.yaml"

echo "=========================================="
echo "Validating Configuration"
echo "=========================================="
echo ""

# Check if custom values file exists
if [ ! -f "$VALUES_FILE" ]; then
  echo -e "${RED}✗ Configuration file not found: $VALUES_FILE${NC}"
  echo ""
  echo "Run: task config:init"
  echo "Then edit $VALUES_FILE with your settings"
  exit 1
fi

echo -e "${GREEN}✓${NC} Found configuration file: $VALUES_FILE"
echo ""

# Function to check if a value is set and not empty/default
check_value() {
  local yaml_path=$1
  local description=$2
  local example=$3

  # Use yq if available, otherwise use grep/sed (less reliable)
  if command -v yq &> /dev/null; then
    value=$(yq eval "$yaml_path" "$VALUES_FILE" 2>/dev/null || echo "")
  else
    # Fallback to grep (less accurate but works without yq)
    value=$(grep -A1 "$yaml_path" "$VALUES_FILE" 2>/dev/null | tail -1 | sed 's/.*: //' | tr -d '"' || echo "")
  fi

  # Check if value is empty, null, or still a placeholder
  if [ -z "$value" ] || [ "$value" = "null" ] || [ "$value" = '""' ] || [[ "$value" == *"CHANGE"* ]] || [[ "$value" == *"example.com"* ]]; then
    echo -e "${RED}✗${NC} Missing: $description"
    echo "   Path: $yaml_path"
    if [ -n "$example" ]; then
      echo "   Example: $example"
    fi
    return 1
  else
    echo -e "${GREEN}✓${NC} $description: $value"
    return 0
  fi
}

# Track validation status
VALIDATION_FAILED=false

echo "Required Configuration:"
echo ""

# Check cert-manager email
if ! check_value ".global.certManager.email" "Let's Encrypt email" "admin@yourdomain.com"; then
  VALIDATION_FAILED=true
fi

# Check panel host
if ! check_value ".global.panel.panelHost" "Panel domain" "panel.yourdomain.com"; then
  VALIDATION_FAILED=true
fi

# Check load balancer configuration
PROVIDER=$(yq eval '.global.loadBalancer.provider' "$VALUES_FILE" 2>/dev/null || echo "metallb")

if [ "$PROVIDER" = "metallb" ]; then
  echo ""
  echo "MetalLB Configuration (provider=metallb):"
  echo ""

  if ! check_value ".global.loadBalancer.metallb.entrypointIP" "MetalLB entrypoint IP" "192.168.1.100"; then
    VALIDATION_FAILED=true
  fi

  # Check IP address pool
  if command -v yq &> /dev/null; then
    ip_pool=$(yq eval '.global.loadBalancer.metallb.ipAddressPool | length' "$VALUES_FILE" 2>/dev/null || echo "0")
    if [ "$ip_pool" -eq 0 ]; then
      echo -e "${RED}✗${NC} Missing: MetalLB IP address pool"
      echo "   Path: .global.loadBalancer.metallb.ipAddressPool"
      echo "   Example: [\"192.168.1.100/32\"]"
      VALIDATION_FAILED=true
    else
      pool_ips=$(yq eval '.global.loadBalancer.metallb.ipAddressPool[]' "$VALUES_FILE" 2>/dev/null)
      echo -e "${GREEN}✓${NC} MetalLB IP pool: $pool_ips"
    fi
  fi
fi

echo ""

# Check storage class (warn if default)
STORAGE_CLASS=$(yq eval '.global.storage.storageClass' "$VALUES_FILE" 2>/dev/null || echo "longhorn")
if [ "$STORAGE_CLASS" = "longhorn" ]; then
  echo -e "${YELLOW}⚠${NC}  Using storage class: $STORAGE_CLASS"
  echo "   Make sure Longhorn is installed or change to your storage class"
else
  echo -e "${GREEN}✓${NC} Storage class: $STORAGE_CLASS"
fi

echo ""

# Final validation result
if [ "$VALIDATION_FAILED" = true ]; then
  echo ""
  echo -e "${RED}=========================================="
  echo "Validation FAILED"
  echo -e "==========================================${NC}"
  echo ""
  echo "Please edit $VALUES_FILE and set all required values"
  echo ""
  exit 1
else
  echo -e "${GREEN}=========================================="
  echo "Validation PASSED"
  echo -e "==========================================${NC}"
  echo ""
fi
