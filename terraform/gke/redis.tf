# Managed Redis, and the in-cluster name pointing at it.
#
# STANDARD_HA keeps a cross-zone replica, fails over automatically, and keeps
# the same IP throughout -- so the plain single-endpoint Jedis pool BMC uses
# needs no client change, and there is no DNS caching to worry about.
#
# The Service is created here, not by the chart, because only this layer knows
# the endpoint.

# Private services access: a reserved range plus a peering connection.
resource "google_compute_global_address" "redis_range" {
  count = var.enable_ha_redis ? 1 : 0

  name          = "${var.cluster_name}-redis-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.bmc.id
}

resource "google_service_networking_connection" "redis" {
  count = var.enable_ha_redis ? 1 : 0

  network                 = google_compute_network.bmc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.redis_range[0].name]

  depends_on = [google_project_service.required]
}

resource "google_redis_instance" "bmc" {
  count = var.enable_ha_redis ? 1 : 0

  name = "${var.cluster_name}-redis"

  # BASIC is a single node, no better than the in-cluster pod.
  tier           = "STANDARD_HA"
  memory_size_gb = var.redis_memory_gb
  region         = var.region

  authorized_network = google_compute_network.bmc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  # No AUTH and no TLS: the clients build a plain JedisPool with no password
  # support, so security here is network isolation -- the instance is reachable
  # only from this VPC. Enabling AUTH requires a client change first
  # (docs/scaling-architecture.md, track B).
  auth_enabled = false

  labels = var.labels

  depends_on = [google_service_networking_connection.redis]
}

# Terraform runs before anything else creates the namespace, and both helmfile
# and generate-secrets.sh reuse an existing one.
#
# Enabling this on an existing install means the namespace exists but is not in
# state. Import it first:
#   tofu import kubernetes_namespace_v1.bmc[0] bmc
resource "kubernetes_namespace_v1" "bmc" {
  count = var.enable_ha_redis ? 1 : 0

  metadata {
    name = var.namespace
  }

  depends_on = [google_container_node_pool.bmc]
}

# An IP endpoint, so ClusterIP plus an explicit EndpointSlice. The IP survives
# failover, so nothing has to watch it.
resource "kubernetes_service_v1" "redis_alias" {
  count = var.enable_ha_redis ? 1 : 0

  metadata {
    name      = "redis-service"
    namespace = var.namespace
    labels = {
      "app"            = "redis"
      "bmc/redis-mode" = "external-ip"
    }
  }

  spec {
    type = "ClusterIP"
    port {
      name        = "redis"
      port        = 6379
      target_port = google_redis_instance.bmc[0].port
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_namespace_v1.bmc]
}

resource "kubernetes_endpoint_slice_v1" "redis_alias" {
  count = var.enable_ha_redis ? 1 : 0

  metadata {
    name      = "redis-service-external"
    namespace = var.namespace
    labels = {
      # Binds the slice to the Service; without it the Service routes nowhere.
      "kubernetes.io/service-name" = "redis-service"
    }
  }

  address_type = "IPv4"

  endpoint {
    addresses = [google_redis_instance.bmc[0].host]
    condition {
      ready = true
    }
  }

  port {
    name         = "redis"
    port         = google_redis_instance.bmc[0].port
    protocol     = "TCP"
    app_protocol = "TCP"
  }

  depends_on = [kubernetes_service_v1.redis_alias]
}
