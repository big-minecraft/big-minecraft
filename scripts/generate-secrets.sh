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
# Use alphanumeric only for database passwords to avoid URL encoding issues
PANEL_SECRET=$(openssl rand -base64 32 | tr -d '\n')
INITIAL_INVITE_CODE=$(openssl rand -base64 12 | tr -d '\n=' | tr -dc 'A-Za-z0-9' | head -c 16)
MARIADB_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | tr -dc 'A-Za-z0-9' | head -c 32)
MONGODB_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | tr -dc 'A-Za-z0-9' | head -c 32)
SFTP_PASSWORD=$(openssl rand -base64 24 | tr -d '\n=' | tr -dc 'A-Za-z0-9' | head -c 24)

echo -e "${GREEN}✓${NC} Generated panel secret (JWT signing key)"
echo -e "${GREEN}✓${NC} Generated initial invite code"
echo -e "${GREEN}✓${NC} Generated MariaDB root password"
echo -e "${GREEN}✓${NC} Generated MongoDB root password"
echo -e "${GREEN}✓${NC} Generated SFTP password"

# Artifact store credentials, under two spellings of the same values:
# artifactAccessKey/artifactSecretKey are what BMC's manifests read, and
# rootUser/rootPassword are the names the MinIO chart requires from an
# existingSecret -- it fails to start without exactly those.
ARTIFACT_ACCESS_KEY=$(openssl rand -hex 16)
ARTIFACT_SECRET_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)
echo -e "${GREEN}✓${NC} Generated artifact store credentials"
echo ""

# Create Kubernetes secret
# The namespace is normally created by helmfile (createNamespace: true), but
# that runs during `task install`, which refuses to start until these secrets
# exist. On a fresh cluster that is a deadlock: no namespace, so no secret; no
# secret, so no install. Create it here -- idempotent, and it is the same
# namespace helmfile would have made.
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "Namespace '$NAMESPACE' does not exist yet; creating it..."
  kubectl create namespace "$NAMESPACE"
  echo ""
fi

echo "Creating Kubernetes secret '$SECRET_NAME' in namespace '$NAMESPACE'..."
echo ""

kubectl create secret generic "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --from-literal=artifactAccessKey="$ARTIFACT_ACCESS_KEY" \
  --from-literal=artifactSecretKey="$ARTIFACT_SECRET_KEY" \
  --from-literal=rootUser="$ARTIFACT_ACCESS_KEY" \
  --from-literal=rootPassword="$ARTIFACT_SECRET_KEY" \
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
