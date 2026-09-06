# The cluster.
#
# Smaller than the EKS equivalent for the same reasons GKE is: the autoscaler is
# a field on the node pool rather than Karpenter plus IAM plus CRDs, the disk
# and file CSI drivers are built in, and Services of type LoadBalancer work
# without installing a controller first.

resource "azurerm_kubernetes_cluster" "bmc" {
  name                = var.cluster_name
  location            = azurerm_resource_group.bmc.location
  resource_group_name = azurerm_resource_group.bmc.name
  dns_prefix          = var.cluster_name
  sku_tier            = var.sku_tier

  # Omitted when empty, which tracks the region's AKS default.
  kubernetes_version = var.kubernetes_version != "" ? var.kubernetes_version : null

  default_node_pool {
    name           = "system"
    vm_size        = var.node_vm_size
    vnet_subnet_id = azurerm_subnet.nodes.id

    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count

    os_disk_size_gb = var.node_disk_size
    zones           = var.node_zones

    upgrade_settings {
      max_surge = "10%"
    }

    tags = var.tags
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    # Overlay, not the classic Azure CNI: without it every pod takes a real
    # subnet address and a busy network exhausts the subnet long before it
    # exhausts the nodes.
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.pods_cidr
    service_cidr        = var.services_cidr
    dns_service_ip      = cidrhost(var.services_cidr, 10)

    # Standard is required for availability zones and for the mixed TCP+UDP
    # game edge. Outbound through the load balancer is the AKS default and
    # needs no NAT gateway of its own.
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_cidrs) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_cidrs
    }
  }

  # Workload Identity, so anything in-cluster that needs an Azure API gets a
  # federated token rather than a stored credential.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  tags = var.tags

  lifecycle {
    # The autoscaler owns the count once the pool exists.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# Spot nodes go in a second pool: AKS will not let the system pool be spot,
# because losing it takes the cluster's own components with it.
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.node_spot ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.bmc.id
  vm_size               = var.node_vm_size
  vnet_subnet_id        = azurerm_subnet.nodes.id

  priority        = "Spot"
  eviction_policy = "Delete"
  # -1 pays up to the on-demand price and is only evicted for capacity, never
  # for price. Anything else adds a second way for a node to vanish.
  spot_max_price = -1

  # Scales from zero, unlike the system pool. Spot draws on a separate and
  # usually much smaller regional quota, so a pool that demands its minimum up
  # front fails to create at all -- ErrCode_InsufficientVCPUQuota -- on exactly
  # the accounts most likely to be experimenting with spot. At zero it costs
  # nothing until something needs it, and quota pressure shows up as pods
  # staying Pending rather than as a failed apply.
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = var.node_max_count

  os_disk_size_gb = var.node_disk_size
  zones           = var.node_zones

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}
