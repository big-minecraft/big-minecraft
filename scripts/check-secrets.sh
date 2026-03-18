#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

NAMESPACE="${NAMESPACE:-default}"
SECRET_NAME="bmc-secrets"

echo "=========================================="
echo "Checking Secrets"
echo "=========================================="
echo ""

# Check if secret exists
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo -e "${GREEN}✓${NC} Secret '$SECRET_NAME' exists in namespace '$NAMESPACE'"
  echo ""

  # List the keys in the secret
  echo "Secret contains the following keys:"
  kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data}' | \
    grep -o '"[^"]*"' | grep -v '{' | tr -d '"' | sed 's/^/  - /'

  echo ""
  echo -e "${GREEN}Secrets are configured correctly${NC}"
else
  echo -e "${YELLOW}✗${NC} Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"
  echo ""
  echo "You need to create secrets before deployment."
  echo ""
  echo "Run: task secrets:generate"
  echo ""
  exit 1
fi

echo ""
