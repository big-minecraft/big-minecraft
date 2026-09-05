output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.bmc.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = google_container_cluster.bmc.endpoint
}

output "configure_kubectl" {
  description = "Point kubectl at the new cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.bmc.name} --region ${var.region} --project ${var.project_id}"
}

output "panel_dns_target" {
  description = "Available after helmfile installs ingress-nginx. GCP load balancers give an IP, so this is an A record, not a CNAME."
  value       = "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "game_dns_target" {
  description = "Available after BMC is installed -- the address players connect to."
  value       = "kubectl get svc proxy-lb -n bmc -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "next_steps" {
  description = "The handoff to the chart layer."
  value       = <<-EOT
    1. gcloud container clusters get-credentials ${google_container_cluster.bmc.name} --region ${var.region} --project ${var.project_id}
    2. task preflight PROFILE=gke     # acceptance test for THIS layer
    3. task config:init PROFILE=gke && edit charts/bmc-chart/values.custom.yaml
    4. task secrets:generate
    5. task install PROFILE=gke
  EOT
}
