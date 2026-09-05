# Security group for the ingress load balancer.
#
# Normally the AWS Load Balancer Controller creates and owns this group,
# populating it from the Service's loadBalancerSourceRanges. That is not enough
# here: this one load balancer now carries two things with different exposure.
#
#   80, 443       the panel. 80 must stay open to the whole internet or
#                 Let's Encrypt HTTP-01 challenges cannot reach the ingress.
#   31400+        SFTP file sessions, forwarded through by ingress-nginx. A
#                 credentialed door into game data, and the opposite of public.
#
# loadBalancerSourceRanges applies to an entire Service, so it cannot express
# that split. Owning the group is what makes per-port rules possible.
#
# The controller is pointed at this group BY NAME from profiles/eks.yaml. The
# two must agree -- see ingress_lb_security_group_name.

resource "aws_security_group" "ingress_lb" {
  name        = var.ingress_lb_security_group_name
  description = "Frontend security group for the BMC ingress load balancer"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = var.ingress_lb_security_group_name })
}

resource "aws_vpc_security_group_ingress_rule" "ingress_lb_http" {
  for_each = toset(var.panel_allowed_cidrs)

  security_group_id = aws_security_group.ingress_lb.id
  description       = "Panel HTTP (also carries ACME HTTP-01 challenges)"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "ingress_lb_https" {
  for_each = toset(var.panel_allowed_cidrs)

  security_group_id = aws_security_group.ingress_lb.id
  description       = "Panel HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# The SFTP block. Empty file_session_allowed_cidrs means no rule at all, which
# here genuinely does mean closed: nothing else opens these ports.
resource "aws_vpc_security_group_ingress_rule" "ingress_lb_sftp" {
  for_each = toset(var.file_session_allowed_cidrs)

  security_group_id = aws_security_group.ingress_lb.id
  description       = "SFTP file sessions, forwarded by ingress-nginx"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.sftp_passthrough_min_port
  to_port           = var.sftp_passthrough_min_port + var.sftp_passthrough_port_count - 1
}

resource "aws_vpc_security_group_egress_rule" "ingress_lb_all" {
  security_group_id = aws_security_group.ingress_lb.id
  description       = "Load balancer to targets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
