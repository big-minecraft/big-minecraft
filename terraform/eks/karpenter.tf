# Karpenter: node autoscaling.
#
# The managed node group in eks.tf stays, deliberately. It runs the things that
# must exist before any autoscaler can: Karpenter itself, CoreDNS, the load
# balancer controller. Karpenter provisions everything above that as game
# server pods appear.
#
# Why this stops being optional once BMC is under load: the GameServer operator
# already scales game server PODS (scaling.minInstances / maxInstances /
# scaleUpThreshold, driven by player count). Without node autoscaling those pods
# simply go Pending once the static group fills -- pod scaling against a fixed
# node count is a ceiling you hit silently under exactly the load you wanted to
# absorb.

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = module.eks.cluster_name

  # Karpenter v1 permission set, matching the chart version pinned below.
  enable_v1_permissions = true

  # EKS Pod Identity rather than IRSA -- fewer moving parts, and the module
  # wires the association itself.
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Spot interruption notices arrive on an SQS queue. Without this a reclaim
  # looks like an abrupt node death rather than a two-minute warning.
  enable_spot_termination = true

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  tags = var.tags
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    serviceAccount = {
      name = module.karpenter.service_account
    }
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    controller = {
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]

  # module.vpc, not just module.eks: uninstalling this runs Karpenter's
  # finalizers, which call AWS APIs from a private subnet. Only the subnets are
  # reached through module.eks, so the NAT gateway is otherwise a free-floating
  # sibling that destroy removes in parallel -- Karpenter then loses egress
  # mid-uninstall and blocks until Helm times out.
  depends_on = [module.eks, module.vpc]
}

# NodePool and EC2NodeClass are custom resources, so they cannot be created
# until the chart above installs its CRDs. A tiny local chart keeps them
# declarative without pulling in a third-party kubectl provider, and without the
# plan-time CRD lookup that makes kubernetes_manifest fail on a fresh apply.
resource "helm_release" "karpenter_nodes" {
  name      = "karpenter-nodes"
  chart     = "${path.module}/charts/karpenter-nodes"
  namespace = "kube-system"

  values = [yamlencode({
    clusterName         = module.eks.cluster_name
    nodeIamRoleName     = module.karpenter.node_iam_role_name
    capacityTypes       = var.karpenter_capacity_types
    instanceCategories  = var.karpenter_instance_categories
    cpuLimit            = var.karpenter_cpu_limit
    consolidationPolicy = var.karpenter_consolidation_policy
    consolidateAfter    = var.karpenter_consolidate_after
    expireAfter         = var.karpenter_expire_after
    tags                = var.tags
  })]

  depends_on = [helm_release.karpenter, module.vpc]
}
