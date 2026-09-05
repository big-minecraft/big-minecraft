# Written for both Terraform and OpenTofu -- nothing here uses syntax specific
# to either. `tofu` and `terraform` are interchangeable in every command below.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
  }

  # Local state is fine for a first cluster and terrible for a second person.
  # Uncomment and fill in before anyone else runs this.
  #
  # backend "s3" {
  #   bucket       = "your-tfstate-bucket"
  #   key          = "bmc/eks/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

# Both providers authenticate with a token minted at apply time rather than a
# long-lived kubeconfig. `aws` must be on PATH for this to work.
#
# These are configured from module.eks outputs, which are unknown until the
# cluster exists. That is the documented pattern in the upstream module's own
# examples and it applies cleanly, but it has one sharp edge: `destroy` needs
# the cluster reachable to evaluate the provider, so destroying a cluster that
# is already gone (or unreachable) leaves the Kubernetes/Helm resources stuck
# in state. Remove them with `state rm` if that happens.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
