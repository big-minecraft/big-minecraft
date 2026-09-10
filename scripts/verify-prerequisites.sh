#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# No default profile. The old fallback to 'baremetal' meant a bare `task verify`
# silently reported on a profile the user had not chosen -- passing on a machine
# with no cloud CLI because it had checked the wrong list. Empty now means
# "report what every profile needs", which is what the Quick Start's first step
# asks for.
PROFILE="${PROFILE:-}"

profile_names() {
  local f
  for f in profiles/*.yaml; do
    [ -e "$f" ] || continue
    basename "$f" .yaml
  done
}

# A typo'd profile must not fall through to the shared-only report and look like
# a pass. `task verify` no longer runs _require-profile (an empty PROFILE is
# meaningful here), so the name check that guard used to provide lives here.
if [ -n "$PROFILE" ] && [ ! -f "profiles/${PROFILE}.yaml" ]; then
  echo -e "${RED}Unknown profile '${PROFILE}'${NC}. Available:"
  profile_names | sed 's/^/  - /'
  exit 1
fi

# The tooling every profile needs, declared once. Both paths below read this
# table -- the check loop and the no-profile listing -- so a shared dependency
# is stated in exactly one place and the two cannot drift. Anything needed by
# only some profiles belongs in the per-profile case blocks further down, which
# remain the source of truth for those.
#
#   command | what it is for | install URL
SHARED_DEPS=(
  "kubectl|talks to the cluster|https://kubernetes.io/docs/tasks/tools/"
  "helm|renders and installs the charts|https://helm.sh/docs/intro/install/"
  "helmfile|orders the releases and their dependencies (v1+, for .gotmpl)|https://github.com/helmfile/helmfile#installation"
  "yq|mikefarah/yq -- reads values for the Taskfile and every config check|https://github.com/mikefarah/yq#install"
)

# Presentation, not declaration: how to coax a version string out of each tool.
# Both of the first two patterns were printing nothing before. kubectl's JSON is
# pretty-printed, so there is a space after the colon that '"gitVersion":"' never
# matched; helmfile leads with a banner, so `head -1` returned its blank line.
dep_version() {
  local v
  case "$1" in
    kubectl)  v=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*' | cut -d'"' -f4) ;;
    helm)     v=$(helm version --short 2>/dev/null) ;;
    helmfile) v=$(helmfile version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1) ;;
    yq)       v=$(yq --version 2>/dev/null) ;;
  esac
  echo "${v:-unknown}"
}

check_shared_deps() {
  local entry cmd why url missing=0
  for entry in "${SHARED_DEPS[@]}"; do
    IFS='|' read -r cmd why url <<< "$entry"
    if command -v "$cmd" &> /dev/null; then
      echo -e "${GREEN}✓${NC} $cmd $(dep_version "$cmd")"
    else
      # Report every missing tool rather than exiting on the first, so one run
      # tells you everything to install.
      echo -e "${RED}✗${NC} $cmd not found -- $why"
      echo "   Install: $url"
      missing=1
    fi
  done
  # yq is the one whose mere presence is not enough: the Python build of the
  # same name emits JSON and quotes string values, which silently corrupts
  # every merged value.
  if command -v yq &> /dev/null && ! yq --version 2>/dev/null | grep -q "mikefarah"; then
    echo -e "${YELLOW}⚠${NC}  This does not look like mikefarah/yq."
    echo "   The Python 'yq' emits JSON and will quote string values."
    echo "   Install: https://github.com/mikefarah/yq#install"
  fi
  [ "$missing" = "0" ]
}

# ------------------------------------------------- no profile: shared only ----
if [ -z "$PROFILE" ]; then
  echo "=========================================="
  echo "Prerequisites shared by every profile"
  echo "=========================================="
  echo ""
  echo "Local tooling -- required whichever profile you install:"
  echo ""
  if check_shared_deps; then
    SHARED_OK=0
  else
    SHARED_OK=1
  fi
  echo ""
  echo "Each profile needs more on top of these -- the tool that builds its"
  echo "cluster, and its provider CLI. Name one to check those too:"
  echo ""
  profile_names | sed 's/^/    task verify PROFILE=/'
  echo ""
  echo "Local tooling is only half the contract. The other half is what the"
  echo "cluster itself must provide -- storage classes, an IngressClass, a"
  echo "LoadBalancer implementation, pod egress. That is per-cluster rather"
  echo "than per-machine, so it needs a profile and a reachable cluster:"
  echo ""
  echo "    task preflight PROFILE=<profile>"
  echo ""
  if [ "$SHARED_OK" != "0" ]; then
    echo -e "${RED}=========================================="
    echo "Missing shared prerequisites -- see above"
    echo -e "==========================================${NC}"
    echo ""
    exit 1
  fi
  echo -e "${GREEN}=========================================="
  echo "Shared Prerequisites Satisfied!"
  echo -e "==========================================${NC}"
  echo ""
  exit 0
fi

# ------------------------------------------------------ a profile is named ----
echo "=========================================="
echo "Verifying Prerequisites"
echo "  profile: $PROFILE"
echo "=========================================="
echo ""

check_shared_deps || exit 1

# Tooling the cloud profiles need on top of the four above. Checked per profile
# rather than always, so a bare-metal install is not asked for an AWS CLI it
# will never use.
case "$PROFILE" in
  baremetal)
    echo ""
    echo "Cluster tooling for profile 'baremetal':"
    # Ansible is this profile's equivalent of OpenTofu: it builds the cluster.
    # Not needed if you already have a cluster and only want to install BMC.
    if command -v ansible-playbook &> /dev/null; then
      echo -e "${GREEN}✓${NC} ansible $(ansible --version 2>/dev/null | head -1 | sed 's/ansible \[//;s/\]//')"
    else
      echo -e "${YELLOW}!${NC} ansible not found"
      echo "   Only needed for 'task cluster PROFILE=baremetal', which builds"
      echo "   the k3s cluster. Skip it if your cluster already exists."
      echo "   Install: brew install ansible | sudo apt install -y ansible"
    fi
    ;;
esac

case "$PROFILE" in
  eks|gke|aks)
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

    if [ "$PROFILE" = "aks" ]; then
      if command -v az &> /dev/null; then
        echo -e "${GREEN}✓${NC} az $(az version -o tsv --query '"azure-cli"' 2>/dev/null)"
        # A logged-in account is not enough on its own: azurerm 4 needs to know
        # which subscription to build in, and an account with several selects
        # none by default. Terraform then fails at plan time rather than login.
        SUB=$(az account show --query name --output tsv 2>/dev/null)
        if [ -n "$SUB" ]; then
          echo -e "${GREEN}✓${NC} Azure subscription: $SUB"
        else
          echo -e "${RED}✗${NC} Azure CLI is not logged in"
          echo "   Run: az login"
          exit 1
        fi

        # The AKS credential plugin. kubectl shells out to it for a token, and
        # `az aks get-credentials` writes a kubeconfig referencing it whether or
        # not it is installed -- so the failure arrives from kubectl after the
        # cluster is already built.
        if command -v kubelogin &> /dev/null; then
          echo -e "${GREEN}✓${NC} kubelogin"
        else
          echo -e "${YELLOW}!${NC} kubelogin not found"
          echo "   Only needed for Entra-integrated clusters. terraform/aks builds"
          echo "   a local-account cluster, which kubectl reaches without it."
          echo "   Install: az aks install-cli"
        fi
      else
        echo -e "${RED}✗${NC} az CLI not found"
        echo "   Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
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
