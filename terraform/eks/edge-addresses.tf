# Static addresses for the two internet-facing load balancers, reserved here so
# DNS can be pointed before install -- cert-manager's HTTP-01 challenge needs
# the panel record to resolve on the first attempt.
#
# One address per load balancer pins each to a single subnet, since the
# allocation count must equal the subnet count. To spread the edge, add subnets
# in config/eks.yaml and an allocation here per subnet.

resource "aws_eip" "ingress" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ingress"
    # Read by teardown:verify, which lists anything still billable.
    "bmc/edge" = "ingress"
  })
}

resource "aws_eip" "game" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name       = "${var.cluster_name}-game"
    "bmc/edge" = "game"
  })
}
