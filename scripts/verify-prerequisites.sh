#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check yq. The Taskfile reads the namespace out of values.yaml with it, and
# validate-config.sh relies on it for every required-value check.
if command -v yq &> /dev/null; then
  YQ_VERSION=$(yq --version 2>/dev/null || echo "unknown")
  echo -e "${GREEN}✓${NC} yq ${YQ_VERSION}"
  if ! yq --version 2>/dev/null | grep -q "mikefarah"; then
    echo -e "${YELLOW}⚠${NC}  This does not look like mikefarah/yq."
    echo "   The Python 'yq' emits JSON and will quote string values."
    echo "   Install: https://github.com/mikefarah/yq#install"
  fi
else
  echo -e "${RED}✗${NC} yq not found"
  echo "   Install: https://github.com/mikefarah/yq#install"
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
