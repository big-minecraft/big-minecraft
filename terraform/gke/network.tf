# VPC-native networking: pods and Services get real VPC addresses from secondary
# ranges, which is what lets GCP's load balancers target pods directly.

resource "google_compute_network" "bmc" {
  name                    = var.cluster_name
  auto_create_subnetworks = false

  # Activation is asynchronous, so the first resource created in a fresh project
  # must wait for it explicitly.
  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "bmc" {
  name          = var.cluster_name
  network       = google_compute_network.bmc.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  # Nodes on private addresses still need to reach Google APIs.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Egress for private nodes.
#
# Not optional while the proxy entrypoint downloads its plugin jar from GitHub
# on every pod start: without egress, every proxy pod fails at boot. The gateway
# bills hourly plus per GB, whether or not anything is downloading.
resource "google_compute_router" "bmc" {
  count = var.private_nodes ? 1 : 0

  name    = "${var.cluster_name}-router"
  network = google_compute_network.bmc.id
  region  = var.region
}

resource "google_compute_router_nat" "bmc" {
  count = var.private_nodes ? 1 : 0

  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.bmc[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}
