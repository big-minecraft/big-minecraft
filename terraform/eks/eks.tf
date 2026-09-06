locals {
  # Security group rules for the node group.
  #
  # Why these are needed at all: every load balancer in this stack is an
  # ip-target NLB, which preserves the client's source IP end to end. The node
  # security group therefore sees real client addresses rather than the load
  # balancer's, so "allow from the VPC" is not sufficient -- and a rule that
  # only allows the VPC CIDR produces a load balancer that provisions cleanly,
  # passes health checks, and drops every real connection.
  game_rules = {
    game_java = {
      description = "Minecraft Java edition (TCP)"
      protocol    = "tcp"
      from_port   = 25565
      to_port     = 25565
      type        = "ingress"
      cidr_blocks = var.game_allowed_cidrs
    }
    game_bedrock = {
      description = "Minecraft Bedrock edition (UDP)"
      protocol    = "udp"
      from_port   = 19132
      to_port     = 19132
      type        = "ingress"
      cidr_blocks = var.game_allowed_cidrs
    }
  }

  panel_rules = {
    panel_http = {
      description = "Panel HTTP via ingress-nginx (also carries ACME HTTP-01 challenges)"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 80
      type        = "ingress"
      cidr_blocks = var.panel_allowed_cidrs
    }
    panel_https = {
      description = "Panel HTTPS via ingress-nginx"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = var.panel_allowed_cidrs
    }
  }

  # Only emitted when a range is actually set: a security group rule with an
  # empty cidr_blocks list is rejected by the API.
  file_session_rules = length(var.file_session_allowed_cidrs) > 0 ? {
    file_session_sftp = {
      description = "SFTP / file-edit sessions, one NLB per open session"
      protocol    = "tcp"
      from_port   = 22
      to_port     = 22
      type        = "ingress"
      cidr_blocks = var.file_session_allowed_cidrs
    }
  } : {}
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Whoever runs `apply` gets cluster-admin, so the same shell can immediately
  # run kubectl and helmfile. Without this you apply successfully and then
  # cannot talk to your own cluster.
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}

    # Serves the credentials endpoint (169.254.170.23) that EKS Pod Identity
    # hands to pods. Karpenter authenticates that way -- see karpenter.tf --
    # and without this agent it starts, blocks forever trying to fetch
    # credentials, fails its health probes and is killed with exit code 2. The
    # pod identity ASSOCIATION existing is not enough; nothing answers without
    # the agent.
    eks-pod-identity-agent = {}
    vpc-cni = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    # Managed addon rather than a Helm release: the EFS driver is what makes
    # ReadWriteMany possible, and RWX is the one storage capability BMC cannot
    # do without -- file-edit and SFTP pods mount a running server's volume
    # alongside it.
    aws-efs-csi-driver = {
      service_account_role_arn = module.efs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      # Not disk_size: this module builds a custom launch template, and
      # disk_size is silently ignored there. Nodes came up on the AMI default
      # instead, which is a fraction of what JDK images need.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  # Same discovery mechanism as the subnets above, for the security group
  # Karpenter attaches to the nodes it creates.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  node_security_group_additional_rules = merge(
    local.game_rules,
    local.panel_rules,
    local.file_session_rules,
  )

  tags = var.tags
}
