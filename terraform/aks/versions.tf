# Written for both Terraform and OpenTofu -- nothing here uses syntax specific
# to either. `tofu` and `terraform` are interchangeable in every command.

terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }

  # Local state is fine for a first cluster and terrible for a second person.
  # backend "azurerm" {
  #   resource_group_name  = "tfstate"
  #   storage_account_name = "yourtfstate"
  #   container_name       = "tfstate"
  #   key                  = "bmc/aks.tfstate"
  # }
}

provider "azurerm" {
  # Required from azurerm 4.0 onward. Falls back to ARM_SUBSCRIPTION_ID, so
  # leaving the variable empty works when that is exported.
  subscription_id = var.subscription_id != "" ? var.subscription_id : null

  features {}
}

# Credentials come from the cluster itself rather than a kubeconfig on disk, so
# `az` does not have to be on PATH for Terraform to reach the API server.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.bmc.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.bmc.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.bmc.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.bmc.kube_config[0].cluster_ca_certificate)
}
