#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PROFILE="${PROFILE:-baremetal-metallb}"

echo "=========================================="
echo "Verifying Prerequisites"
echo "  profile: $PROFILE"
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

# Tooling the cloud profiles need on top of the four above. Checked per profile
# rather than always, so a bare-metal install is not asked for an AWS CLI it
# will never use.
case "$PROFILE" in
  eks|gke)
    echo ""
    echo "Cloud tooling for profile '$PROFILE':"

    if command -v tofu &> /dev/null; then
      echo -e "${GREEN}✓${NC} tofu $(tofu version 2>/dev/null | head -1)"
    elif command -v terraform &> /dev/null; then
      echo -e "${GREEN}✓${NC} terraform $(terraform version 2>/dev/null | head -1)"
    else
      echo -e "${RED}✗${NC} neither tofu nor terraform found"
      echo "   Install: https://opentofu.org/docs/intro/install/"
      exit 1
    fi

    if [ "$PROFILE" = "eks" ]; then
      if command -v aws &> /dev/null; then
        echo -e "${GREEN}✓${NC} aws $(aws --version 2>&1 | head -1)"
        # Credentials, not just the binary: every later step fails without them,
        # and the errors point at the cluster rather than at the shell.
        if aws sts get-caller-identity &> /dev/null; then
          echo -e "${GREEN}✓${NC} AWS credentials: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
        else
          echo -e "${RED}✗${NC} AWS credentials are not configured"
          echo "   Run: aws configure"
          exit 1
        fi
      else
        echo -e "${RED}✗${NC} aws CLI not found"
        echo "   Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
      fi
    fi

    if [ "$PROFILE" = "gke" ]; then
      if command -v gcloud &> /dev/null; then
        echo -e "${GREEN}✓${NC} gcloud $(gcloud version 2>/dev/null | head -1)"
        ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
        if [ -n "$ACCOUNT" ]; then
          echo -e "${GREEN}✓${NC} gcloud account: $ACCOUNT"
        else
          echo -e "${RED}✗${NC} gcloud is not authenticated"
          echo "   Run: gcloud auth login"
          exit 1
        fi

        # Application Default Credentials, checked SEPARATELY and on purpose.
        #
        # `gcloud auth login` and `gcloud auth application-default login` write
        # two different credential stores. gcloud commands use the first;
        # Terraform's google provider uses the second. Checking only the first
        # reports a healthy setup while `tofu apply` fails on
        # data.google_client_config with "invalid_grant: Bad Request".
        #
        # Minting a token is the only real test: the ADC file can sit on disk
        # for a year with a refresh token that was revoked or expired long ago.
        if gcloud auth application-default print-access-token &> /dev/null; then
          echo -e "${GREEN}✓${NC} application default credentials are valid"
        else
          echo -e "${RED}✗${NC} application default credentials are missing or expired"
          echo "   Terraform's google provider uses these, not the account above."
          echo "   Run: gcloud auth application-default login"
          exit 1
        fi
        # kubectl cannot talk to a GKE cluster without this. Since Kubernetes
        # 1.26 the in-tree GCP auth provider is gone, so kubectl shells out to
        # this binary for a token -- and gcloud writes a kubeconfig that
        # references it whether or not it is installed. The failure therefore
        # arrives after the cluster is built, from kubectl rather than gcloud.
        if command -v gke-gcloud-auth-plugin &> /dev/null; then
          echo -e "${GREEN}✓${NC} gke-gcloud-auth-plugin"
        else
          echo -e "${RED}✗${NC} gke-gcloud-auth-plugin not found"
          echo "   kubectl cannot authenticate to GKE without it."
          echo "   Run: gcloud components install gke-gcloud-auth-plugin"
          echo "   (Homebrew installs disable the component manager --"
          echo "    use: brew install --cask gcloud-cli)"
          exit 1
        fi

        PROJECT=$(gcloud config get-value project 2>/dev/null)
        if [ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ]; then
          echo -e "${GREEN}✓${NC} gcloud project: $PROJECT"
        else
          echo -e "${YELLOW}⚠${NC}  no default gcloud project set"
          echo "   Terraform takes project_id from terraform.tfvars, so this is"
          echo "   only needed for gcloud commands you run by hand."
        fi
      else
        echo -e "${RED}✗${NC} gcloud CLI not found"
        echo "   Install: https://cloud.google.com/sdk/docs/install"
        exit 1
      fi
    fi
    ;;
esac

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
