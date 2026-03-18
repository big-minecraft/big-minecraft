#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "=========================================="
echo "Configuring Traefik IP Sharing"
echo "=========================================="
echo ""

# Check if Traefik exists in kube-system
if ! kubectl get svc traefik -n kube-system &>/dev/null; then
  echo -e "${GREEN}✓${NC} Traefik not found in kube-system - no IP sharing configuration needed"
  echo ""
  exit 0
fi

# Check if Traefik already has the sharing annotation
CURRENT_ANNOTATION=$(kubectl get svc traefik -n kube-system -o jsonpath='{.metadata.annotations.metallb\.io/allow-shared-ip}' 2>/dev/null)

if [ -n "$CURRENT_ANNOTATION" ]; then
  echo -e "${GREEN}✓${NC} Traefik already configured for IP sharing with key: $CURRENT_ANNOTATION"
  echo ""
  exit 0
fi

# Add the sharing annotation to Traefik
echo "Adding IP sharing annotation to Traefik service..."
if kubectl annotate svc traefik -n kube-system metallb.io/allow-shared-ip=shared-ip-key --overwrite; then
  echo ""
  echo -e "${GREEN}✓${NC} Traefik configured to allow IP sharing"
  echo "   This allows multiple services to use the same LoadBalancer IP"
  echo ""
else
  echo ""
  echo -e "${RED}✗${NC} Failed to annotate Traefik service"
  echo ""
  exit 1
fi
