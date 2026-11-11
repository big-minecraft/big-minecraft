# Security group for the ingress load balancer, owned here rather than by the
# controller: loadBalancerSourceRanges applies to a whole Service, and this one
# carries ports with different exposure -- 80/443 must stay open to the internet
# for HTTP-01, the SFTP ports must not.
#
# profiles/eks.yaml points the controller at this group by name; the two must
# agree. See ingress_lb_security_group_name.

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

# Empty file_session_allowed_cidrs means no rule, which here means closed.
resource "aws_vpc_security_group_ingress_rule" "ingress_lb_sftp" {
  for_each = toset(var.file_session_allowed_cidrs)

  security_group_id = aws_security_group.ingress_lb.id
  description       = "SFTP file sessions, forwarded by Traefik"
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
