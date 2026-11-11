# Static addresses for the two internet-facing load balancers, reserved here so
# DNS can be pointed before install -- cert-manager's HTTP-01 challenge needs
# the panel record to resolve on the first attempt.
#
# Regional, not global: a global address only attaches to an L7 load balancer.

resource "google_compute_address" "ingress" {
  name         = "${var.cluster_name}-ingress"
  region       = var.region
  address_type = "EXTERNAL"
  description  = "BMC panel ingress. Point global.ingress.host here."
}

resource "google_compute_address" "game" {
  name         = "${var.cluster_name}-game"
  region       = var.region
  address_type = "EXTERNAL"
  description  = "BMC game edge. The address players connect to."
}
