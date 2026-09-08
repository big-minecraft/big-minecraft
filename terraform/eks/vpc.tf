data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20s for pods (the VPC CNI hands each pod a real VPC address, so private
  # subnets exhaust far faster than they would on an overlay CNI), /24s for the
  # load balancers.
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  # Private /20s run from .0 up; public /24s start at .128 so the two ranges
  # cannot collide until well past the AZ count any region offers.
  public_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 128)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # The AWS Load Balancer Controller discovers subnets by tag. Without these it
  # fails to place a load balancer and the Service sits in <pending> forever,
  # with the reason visible only in the controller's own logs.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    # Karpenter discovers where to place nodes by this tag. Without it the
    # controller runs, accepts NodePools, and never launches an instance --
    # the reason appears only in its logs.
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}
