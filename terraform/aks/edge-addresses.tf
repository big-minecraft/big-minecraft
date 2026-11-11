# Static addresses for the two internet-facing load balancers, reserved here so
# DNS can be pointed before install -- cert-manager's HTTP-01 challenge needs
# the panel record to resolve on the first attempt.
#
# In the cluster's node resource group, where AKS's identity can already attach
# them, and which AKS deletes with the cluster.

resource "azurerm_public_ip" "ingress" {
  name                = "${var.cluster_name}-ingress"
  resource_group_name = azurerm_kubernetes_cluster.bmc.node_resource_group
  location            = azurerm_resource_group.bmc.location
  allocation_method   = "Static"
  sku                 = "Standard"

  # Dashes, not a slash: Azure rejects '/' in a tag name.
  tags = {
    "bmc-edge" = "ingress"
  }
}

resource "azurerm_public_ip" "game" {
  name                = "${var.cluster_name}-game"
  resource_group_name = azurerm_kubernetes_cluster.bmc.node_resource_group
  location            = azurerm_resource_group.bmc.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    "bmc-edge" = "game"
  }
}
