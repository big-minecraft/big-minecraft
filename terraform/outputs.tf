output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "efs_file_system_id" {
  description = "EFS filesystem backing the shared (RWX) storage class."
  value       = aws_efs_file_system.bmc.id
}

output "storage_classes" {
  description = "Must match global.storage.classes.* in profiles/eks.yaml."
  value = {
    shared   = kubernetes_storage_class_v1.efs.metadata[0].name
    database = kubernetes_storage_class_v1.gp3.metadata[0].name
  }
}

output "configure_kubectl" {
  description = "Point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "panel_dns_target" {
  description = "Available only after helmfile installs ingress-nginx. Resolve the hostname, then point global.ingress.host and global.panel.panelHost at it with a CNAME."
  value       = "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "game_dns_target" {
  description = "Available only after BMC is installed -- this is the address players connect to."
  value       = "kubectl get svc proxy-lb -n bmc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "next_steps" {
  description = "The handoff to the chart layer."
  value       = <<-EOT
    1. aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
    2. task preflight PROFILE=eks     # acceptance test for THIS layer
    3. task config:init && edit charts/bmc-chart/values.custom.yaml
       (ingress.host, panel.panelHost, certManager.email, edge.*.sourceRanges)
    4. task secrets:generate
    5. task install PROFILE=eks
  EOT
}
