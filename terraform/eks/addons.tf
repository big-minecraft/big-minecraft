# In-cluster components this layer owns -- only what needs cloud credentials or
# a cloud resource ID. cert-manager and Traefik are deliberately absent:
# helmfile installs both, and a second owner would fight it over the CRDs.

# Mandatory: the game edge carries TCP and UDP on one Service, and the in-tree
# provider silently drops every Bedrock packet.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.load_balancer_controller_chart_version
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.load_balancer_controller_irsa.iam_role_arn
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "region"
    value = var.region
  }

  depends_on = [module.eks]
}

# Traefik depends on the controller above, and helmfile runs after this layer,
# so the ordering holds.
