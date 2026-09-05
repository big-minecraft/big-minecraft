# In-cluster components this layer owns.
#
# NOTE what is deliberately absent: cert-manager. helmfile.yaml already
# installs it, gated on `eq .Values.global.ingress.tls.mode "cluster-issuer"`,
# which profiles/eks.yaml sets. Installing it here too would give one release
# two owners, and the first `helmfile apply` would fight this layer over the
# CRDs. Same reasoning for MetalLB and Traefik: helmfile decides, and the eks
# profile turns both off.

# Mandatory, not optional. The game edge is one Service carrying TCP 25565 and
# UDP 19132; the deprecated in-tree provider cannot do UDP at all and will hand
# back a healthy-looking Classic LB that silently drops every Bedrock packet.
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

# NOTE what else is absent: ingress-nginx. It needs nothing from AWS, so it is
# installed by helmfile as a profile-gated release (global.ingressNginx.install,
# true in profiles/eks.yaml) alongside cert-manager and MetalLB. The rule this
# layer follows: Terraform owns only what requires cloud credentials or
# references a cloud resource ID -- the controller above needs an IRSA role ARN,
# the EFS storage class needs a filesystem ID, and nothing else qualifies.
#
# ingress-nginx does depend on the controller above, and helmfile runs after
# this layer, so that ordering holds without either tool knowing about the other.
