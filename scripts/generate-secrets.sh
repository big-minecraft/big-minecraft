#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="${NAMESPACE:-default}"
SECRET_NAME="bmc-secrets"

echo "=========================================="
echo "Generating BMC Secrets"
echo "=========================================="
echo ""

# Check if secret already exists
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo -e "${YELLOW}⚠${NC}  Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'"
  echo ""
  read -p "Do you want to DELETE and recreate it? (yes/no): " -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Aborted. Keeping existing secret."
    exit 0
  fi
  echo "Deleting existing secret..."
  kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
  echo ""
fi

# Generate random secrets
echo "Generating random secrets..."
echo ""

# Check if openssl is available
if ! command -v openssl &> /dev/null; then
  echo -e "${RED}Error: openssl is required but not installed${NC}"
  exit 1
fi

# Generate secrets
PANEL_SECRET=$(openssl rand -base64 32 | tr -d '\n')
INITIAL_INVITE_CODE=$(openssl rand -base64 12 | tr -d '\n=' | tr -dc 'A-Za-z0-9' | head -c 16)
MARIADB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
MONGODB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
SFTP_PASSWORD=$(openssl rand -base64 16 | tr -d '\n')

echo -e "${GREEN}✓${NC} Generated panel secret (JWT signing key)"
echo -e "${GREEN}✓${NC} Generated initial invite code"
echo -e "${GREEN}✓${NC} Generated MariaDB root password"
echo -e "${GREEN}✓${NC} Generated MongoDB root password"
echo -e "${GREEN}✓${NC} Generated SFTP password"
echo ""

# Create Kubernetes secret
echo "Creating Kubernetes secret '$SECRET_NAME' in namespace '$NAMESPACE'..."
echo ""

kubectl create secret generic "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --from-literal=panelSecret="$PANEL_SECRET" \
  --from-literal=initialInviteCode="$INITIAL_INVITE_CODE" \
  --from-literal=mariadb-root-password="$MARIADB_PASSWORD" \
  --from-literal=mongodb-root-password="$MONGODB_PASSWORD" \
  --from-literal=sftp-password="$SFTP_PASSWORD"

echo ""
echo -e "${GREEN}=========================================="
echo "✓ Secrets Created Successfully"
echo -e "==========================================${NC}"
echo ""
echo -e "${BLUE}IMPORTANT - Save these credentials:${NC}"
echo ""
echo -e "${YELLOW}Initial Invite Code:${NC} $INITIAL_INVITE_CODE"
echo ""
echo "Use this code to create your first admin user when accessing the panel."
echo ""
echo -e "${YELLOW}Database Credentials:${NC}"
echo "  MariaDB root password: $MARIADB_PASSWORD"
echo "  MongoDB root password: $MONGODB_PASSWORD"
echo "  SFTP password: $SFTP_PASSWORD"
echo ""
echo -e "${RED}⚠  Store these credentials securely!${NC}"
echo "   They are only shown once and cannot be recovered."
echo ""
echo "To view secret keys later (base64 encoded):"
echo "  kubectl get secret $SECRET_NAME -n $NAMESPACE -o yaml"
echo ""
