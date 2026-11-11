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

output "panel_dns_records" {
  description = "A record for global.ingress.host and global.panel.panelHost. Point DNS here before `task install`, or the first certificate fails. Set as global.ingress.controller.service.loadBalancerIP in config/gke.yaml."
  value       = google_compute_address.ingress.address
}

output "game_dns_records" {
  description = "A record for the address players connect to. Set it as global.edge.game.loadBalancerIP in config/gke.yaml."
  value       = google_compute_address.game.address
}

output "next_steps" {
  description = "The handoff to the chart layer."
  value       = <<-EOT
    1. gcloud container clusters get-credentials ${google_container_cluster.bmc.name} --region ${var.region} --project ${var.project_id}
    2. task preflight PROFILE=gke     # acceptance test for THIS layer
    3. task config:init PROFILE=gke && edit config/gke.yaml
       (set loadBalancerIP from panel_dns_records and game_dns_records above)
    4. Point DNS at those addresses, and wait for it to resolve -- the first
       certificate fails otherwise.
    5. task secrets:generate
    6. task install PROFILE=gke
  EOT
}
