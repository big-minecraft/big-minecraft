# Managed Redis, and the in-cluster name pointing at it.
#
# Cluster mode DISABLED is required, not a preference: it presents one primary
# endpoint that AWS repoints on failover, which the plain single-endpoint Jedis
# pool BMC uses handles with no client change. Cluster mode ENABLED shards the
# keyspace, and the manager enumerates instances with SCAN -- per-node in a
# sharded cluster, so it would silently return partial lists.
#
# The Service is created here, not by the chart, for the same reason as the
# efs-sc StorageClass: only this layer knows the endpoint.

resource "aws_elasticache_subnet_group" "redis" {
  count = var.enable_ha_redis ? 1 : 0

  name       = "${var.cluster_name}-redis"
  subnet_ids = module.vpc.private_subnets

  tags = var.tags
}

resource "aws_security_group" "redis" {
  count = var.enable_ha_redis ? 1 : 0

  name        = "${var.cluster_name}-redis"
  description = "Redis access from the EKS nodes"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.cluster_name}-redis" })
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_nodes" {
  count = var.enable_ha_redis ? 1 : 0

  security_group_id            = aws_security_group.redis[0].id
  description                  = "Redis from cluster nodes"
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_elasticache_replication_group" "redis" {
  count = var.enable_ha_redis ? 1 : 0

  replication_group_id = "${var.cluster_name}-redis"
  description          = "BMC coordination and scaling state"

  engine             = "redis"
  node_type          = var.redis_node_type
  num_cache_clusters = 2

  # Multi-AZ places the replica in another zone; automatic failover promotes it
  # and repoints the primary endpoint.
  multi_az_enabled           = true
  automatic_failover_enabled = true

  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.redis[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  # No AUTH token and no TLS: the clients build a plain JedisPool with no
  # password support, so security here is network isolation only -- the
  # security group above allows the node group and nothing else. Enabling AUTH
  # requires a client change first (docs/scaling-architecture.md, track B).
  transit_encryption_enabled = false
  at_rest_encryption_enabled = true

  # Coordination state, rebuilt from live instances on restart -- snapshots would
  # cost storage for no benefit.
  snapshot_retention_limit = 0

  apply_immediately = true

  tags = var.tags
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

  depends_on = [module.eks]
}

# The alias. ElastiCache gives a hostname, so this is an ExternalName Service --
# clients resolve redis-service and land on the primary endpoint, and AWS moves
# that endpoint on failover without anything in the cluster changing.
resource "kubernetes_service_v1" "redis_alias" {
  count = var.enable_ha_redis ? 1 : 0

  metadata {
    name      = "redis-service"
    namespace = var.namespace
    labels = {
      "app"            = "redis"
      "bmc/redis-mode" = "external-name"
    }
  }

  spec {
    type          = "ExternalName"
    external_name = aws_elasticache_replication_group.redis[0].primary_endpoint_address
  }

  depends_on = [kubernetes_namespace_v1.bmc]
}
