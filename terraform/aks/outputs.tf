output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.bmc.name
}

output "resource_group" {
  description = "Resource group holding every resource this layer created."
  value       = azurerm_resource_group.bmc.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = azurerm_kubernetes_cluster.bmc.kube_config[0].host
  sensitive   = true
}

output "configure_kubectl" {
  description = "Point kubectl at the new cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.bmc.name} --name ${azurerm_kubernetes_cluster.bmc.name}"
}

output "panel_dns_records" {
  description = "A record for global.ingress.host and global.panel.panelHost. Point DNS here before `task install`, or the first certificate fails. Set as global.ingress.controller.service.loadBalancerIP in config/aks.yaml."
  value       = azurerm_public_ip.ingress.ip_address
}

output "game_dns_records" {
  description = "A record for the address players connect to. Set it as global.edge.game.loadBalancerIP in config/aks.yaml."
  value       = azurerm_public_ip.game.ip_address
}

output "next_steps" {
  description = "The handoff to the chart layer."
  value       = <<-EOT
    1. az aks get-credentials --resource-group ${azurerm_resource_group.bmc.name} --name ${azurerm_kubernetes_cluster.bmc.name}
    2. task preflight PROFILE=aks     # acceptance test for THIS layer
    3. task config:init PROFILE=aks && edit config/aks.yaml
    4. task secrets:generate
    5. task install PROFILE=aks
  EOT
}
