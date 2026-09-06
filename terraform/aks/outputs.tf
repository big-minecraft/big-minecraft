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

output "panel_dns_target" {
  description = "Available after helmfile installs ingress-nginx. Azure load balancers give an IP, so this is an A record, not a CNAME."
  value       = "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "game_dns_target" {
  description = "Available after BMC is installed -- the address players connect to."
  value       = "kubectl get svc proxy-lb -n bmc -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "next_steps" {
  description = "The handoff to the chart layer."
  value       = <<-EOT
    1. az aks get-credentials --resource-group ${azurerm_resource_group.bmc.name} --name ${azurerm_kubernetes_cluster.bmc.name}
    2. task preflight PROFILE=aks     # acceptance test for THIS layer
    3. task config:init PROFILE=aks && edit charts/bmc-chart/values.custom.yaml
    4. task secrets:generate
    5. task install PROFILE=aks
  EOT
}
