#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Verifying Prerequisites"
echo "=========================================="
echo ""

# Check kubectl
if command -v kubectl &> /dev/null; then
  KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*' | cut -d'"' -f4 || echo "unknown")
  echo -e "${GREEN}✓${NC} kubectl ${KUBECTL_VERSION}"
else
  echo -e "${RED}✗${NC} kubectl not found"
  echo "   Install: https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi

# Check helm
if command -v helm &> /dev/null; then
  HELM_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
  echo -e "${GREEN}✓${NC} helm ${HELM_VERSION}"
else
  echo -e "${RED}✗${NC} helm not found"
  echo "   Install: https://helm.sh/docs/intro/install/"
  exit 1
fi

# Check helmfile
if command -v helmfile &> /dev/null; then
  HELMFILE_VERSION=$(helmfile version 2>/dev/null | head -1 || echo "unknown")
  echo -e "${GREEN}✓${NC} helmfile ${HELMFILE_VERSION}"
else
  echo -e "${RED}✗${NC} helmfile not found"
  echo "   Install: https://github.com/helmfile/helmfile#installation"
  exit 1
fi

# Check cluster connection
echo ""
echo "Checking cluster connection..."
if kubectl cluster-info &> /dev/null; then
  CLUSTER=$(kubectl config current-context)
  echo -e "${GREEN}✓${NC} Connected to cluster: ${CLUSTER}"
else
  echo -e "${RED}✗${NC} Cannot connect to Kubernetes cluster"
  echo "   Check your kubectl configuration and cluster status"
  exit 1
fi

echo ""
echo -e "${GREEN}=========================================="
echo "All Prerequisites Satisfied!"
echo -e "==========================================${NC}"
echo ""
