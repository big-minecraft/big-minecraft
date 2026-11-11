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

output "panel_dns_records" {
  description = "A record for global.ingress.host and global.panel.panelHost. Point DNS here before `task install`, or the first certificate fails."
  value       = [aws_eip.ingress.public_ip]
}

output "game_dns_records" {
  description = "A record for the address players connect to."
  value       = [aws_eip.game.public_ip]
}

output "edge_subnet_ids" {
  description = "Must match global.ingress.controller.service.subnets and global.edge.game.subnets in config/eks.yaml -- one subnet per reserved address."
  value       = [module.vpc.public_subnets[0]]
}

output "ingress_eip_allocation_ids" {
  description = "Must match global.ingress.controller.service.eipAllocations in config/eks.yaml."
  value       = [aws_eip.ingress.id]
}

output "game_eip_allocation_ids" {
  description = "Must match global.edge.game.eipAllocations in config/eks.yaml."
  value       = [aws_eip.game.id]
}

output "next_steps" {
  description = "The handoff to the chart layer."
  value       = <<-EOT
    1. aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
    2. task preflight PROFILE=eks     # acceptance test for THIS layer
    3. task config:init && edit config/eks.yaml
       (ingress.host, panel.panelHost, certManager.email, edge.*.sourceRanges,
        and the eipAllocations lists -- see ingress_eip_allocation_ids above)
    4. Point DNS at panel_dns_records and game_dns_records, and wait for it to
       resolve -- the first certificate fails otherwise.
    5. task secrets:generate
    6. task install PROFILE=eks
  EOT
}

