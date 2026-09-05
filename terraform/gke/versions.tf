# Written for both Terraform and OpenTofu -- nothing here uses syntax specific
# to either. `tofu` and `terraform` are interchangeable in every command.

terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }

  # Local state is fine for a first cluster and terrible for a second person.
  # backend "gcs" {
  #   bucket = "your-tfstate-bucket"
  #   prefix = "bmc/gke"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Token minted at apply time rather than a long-lived kubeconfig. `gcloud` does
# not need to be on PATH for this -- the provider mints it itself.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.bmc.endpoint}"
  cluster_ca_certificate = base64decode(google_container_cluster.bmc.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}
