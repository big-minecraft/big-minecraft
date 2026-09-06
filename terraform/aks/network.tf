# Everything this layer builds lives in one resource group, so deleting the
# group is a complete teardown even if Terraform state is lost.
resource "azurerm_resource_group" "bmc" {
  name     = var.resource_group_name != "" ? var.resource_group_name : "${var.cluster_name}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "bmc" {
  name                = var.cluster_name
  location            = azurerm_resource_group.bmc.location
  resource_group_name = azurerm_resource_group.bmc.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# Only nodes draw addresses from this subnet. Pods are on an overlay, so a /20
# does not run out the way an EKS private subnet does under the VPC CNI, where
# every pod takes a real subnet address.
resource "azurerm_subnet" "nodes" {
  name                 = "${var.cluster_name}-nodes"
  resource_group_name  = azurerm_resource_group.bmc.name
  virtual_network_name = azurerm_virtual_network.bmc.name
  address_prefixes     = [var.node_subnet_cidr]
}
