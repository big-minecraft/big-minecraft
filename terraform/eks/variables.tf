variable "region" {
  description = "AWS region to build in."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the prefix for most resources."
  type        = string
  default     = "bmc"
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane version. Must be >= 1.26: the game edge is a single
    Service carrying both TCP and UDP, and MixedProtocolLBService only went GA
    in 1.26. `task preflight PROFILE=eks` checks this against the live cluster.
  EOT
  type        = string
  default     = "1.31"

  validation {
    condition     = tonumber(split(".", var.kubernetes_version)[1]) >= 26
    error_message = "BMC needs Kubernetes >= 1.26 for a mixed TCP+UDP LoadBalancer Service."
  }
}

# ------------------------------------------------------------------ network --

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many availability zones to spread across. EFS gets one mount target per AZ."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6 (below 2 there is no AZ redundancy; above 6 the private /20s would collide with the public subnet range)."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    One NAT gateway for all private subnets (true) or one per AZ (false).

    This is not optional infrastructure for BMC: the proxy entrypoint downloads
    bmc-velocity.jar from GitHub on EVERY pod start, so private nodes with no
    egress produce proxies that crash-loop at boot. A NAT gateway bills hourly
    plus per-GB whether or not anything is downloading.

    true is cheaper and is a single-AZ failure domain for egress. false is
    ~3x the hourly cost and survives an AZ loss.
  EOT
  type        = bool
  default     = true
}

# -------------------------------------------------------------------- nodes --

variable "node_instance_types" {
  description = "Instance types for the managed node group. Minecraft is single-threaded per server and latency-sensitive; prefer fewer fast cores over many slow ones."
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "node_group_min_size" {
  description = "Minimum nodes."
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum nodes."
  type        = number
  default     = 6
}

variable "node_group_desired_size" {
  description = "Starting node count. Ignored after creation -- scaling is left to whatever manages it in-cluster."
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Root EBS volume per node, in GiB. Game data lives on EFS, but container images (eclipse-temurin JDK ones are large) live here."
  type        = number
  default     = 50
}

# ------------------------------------------------------------------ access --

variable "cluster_endpoint_public_access_cidrs" {
  description = "Who may reach the Kubernetes API. Defaults to the whole internet, which is the usual default and still worth narrowing to your operators."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "game_allowed_cidrs" {
  description = <<-EOT
    Node-level allowance for the game ports (TCP 25565, UDP 19132).

    NOTE: this is defence in depth, NOT the control that gates players.

    The AWS Load Balancer Controller gives each Service its own frontend
    security group and populates it from the Service's loadBalancerSourceRanges
    -- which comes from global.edge.game.sourceRanges in values.custom.yaml.
    That is the authoritative control. The controller also manages the
    load-balancer-to-pod path itself (the rule tagged
    elbv2.k8s.aws/targetGroupBinding=shared), so these node rules are a second
    layer rather than the first.

    Setting this to a narrow range while leaving edge.game.sourceRanges empty
    does NOT restrict anything: the listener stays open to 0.0.0.0/0.

    A public Minecraft server wants 0.0.0.0/0 in both places.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "file_session_allowed_cidrs" {
  description = <<-EOT
    Who may reach SFTP / file-edit sessions, on the ingress load balancer's
    SFTP port block (see sftp_passthrough_min_port).

    Defaults to the whole internet so file sessions work out of the box. That
    means an open session is reachable by anyone who knows the address, with
    only the shared SFTP password in the way -- and that password is the same
    for every deployment and does not rotate between sessions.

    To restrict later, replace with the addresses you actually connect from:

      file_session_allowed_cidrs = ["203.0.113.4/32"]

    An empty list creates no rule at all, which closes the ports entirely.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "panel_allowed_cidrs" {
  description = "Who may reach the panel over HTTP/HTTPS (ports 80, 443 via ingress-nginx). 0.0.0.0/0 is required if you want Let's Encrypt HTTP-01 challenges to succeed."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -------------------------------------------------------------------- addons --

variable "load_balancer_controller_chart_version" {
  description = "aws-load-balancer-controller chart version. Mandatory component: the in-tree provider cannot do UDP at all."
  type        = string
  default     = "1.8.4"
}

variable "efs_throughput_mode" {
  description = "EFS throughput mode. 'elastic' scales with load and is the sane default; 'bursting' is cheaper for consistently light use."
  type        = string
  default     = "elastic"
}

variable "tags" {
  description = "Tags applied to everything."
  type        = map(string)
  default = {
    Project   = "big-minecraft"
    ManagedBy = "opentofu"
  }
}

# ---------------------------------------------------------------- karpenter --

variable "karpenter_chart_version" {
  description = "Karpenter chart version, from oci://public.ecr.aws/karpenter."
  type        = string
  default     = "1.14.1"
}

variable "karpenter_capacity_types" {
  description = <<-EOT
    Capacity types Karpenter may buy.

    on-demand only, by default. Adding "spot" is roughly a 70% saving and a
    two-minute eviction notice: AWS reclaims the instance and every Minecraft
    server on it restarts, mid-session. The interruption queue is wired up, so
    the shutdown is graceful rather than abrupt -- but it is still a shutdown.
    Reasonable for a test cluster, rarely for players.
  EOT
  type        = list(string)
  default     = ["on-demand"]
}

variable "karpenter_instance_categories" {
  description = "EC2 instance categories Karpenter may pick from. m/c/r covers general, compute and memory optimised."
  type        = list(string)
  default     = ["m", "c", "r"]
}

variable "karpenter_cpu_limit" {
  description = "Total vCPUs Karpenter may provision across all its nodes. The backstop against a runaway scale-up billing you for a fleet."
  type        = string
  default     = "200"
}

variable "karpenter_consolidation_policy" {
  description = <<-EOT
    WhenEmpty or WhenEmptyOrUnderutilized.

    WhenEmpty is the default and the safe one: a node is reclaimed only once
    nothing is running on it. WhenEmptyOrUnderutilized additionally evicts
    running pods to pack nodes tighter -- which on this workload means killing
    live game servers to save an instance-hour.

    The per-pod escape hatch (karpenter.sh/do-not-disrupt) is not available
    here: the GameServer CRD exposes no annotations field, so nothing can mark
    a game pod as immovable until bmc-manager adds that passthrough.
  EOT
  type        = string
  default     = "WhenEmpty"

  validation {
    condition     = contains(["WhenEmpty", "WhenEmptyOrUnderutilized"], var.karpenter_consolidation_policy)
    error_message = "Must be WhenEmpty or WhenEmptyOrUnderutilized."
  }
}

variable "karpenter_consolidate_after" {
  description = "How long a node stays empty before Karpenter reclaims it. Long enough that a brief lull between matches does not churn nodes."
  type        = string
  default     = "5m"
}

variable "karpenter_expire_after" {
  description = "Node lifetime before replacement, which is what keeps AMIs patched. This is a planned disruption -- nodes drain and their game servers restart. \"Never\" opts out and leaves patching to you."
  type        = string
  default     = "720h"
}

# ------------------------------------------------------- ingress LB group ----

variable "ingress_lb_security_group_name" {
  description = <<-EOT
    Name of the security group fronting the ingress load balancer.

    profiles/eks.yaml references this by name in the
    service.beta.kubernetes.io/aws-load-balancer-security-groups annotation, so
    the two must match. Changing it here means changing it there.
  EOT
  type        = string
  default     = "bmc-ingress-lb"
}

variable "sftp_passthrough_min_port" {
  description = "First port of the SFTP block ingress-nginx forwards. Must match global.ingressNginx.sftpPassthrough.minPort, which in turn matches MIN_SFTP_PORT_RANGE in the panel."
  type        = number
  default     = 31400
}

variable "sftp_passthrough_port_count" {
  description = "How many SFTP ports to open. Must match global.ingressNginx.sftpPassthrough.portCount. Bounded by the NLB's 50-listener limit."
  type        = number
  default     = 20
}

# -------------------------------------------------------------- HA redis ----

variable "enable_ha_redis" {
  description = <<-EOT
    Provision ElastiCache and point redis-service at it, instead of running the
    single in-cluster Redis pod.

    On by default because Redis is the one component whose loss stops scaling
    cluster-wide, and the in-cluster default has no failover.

    Costs roughly $45/month for two cache.t4g.small nodes (primary plus a
    replica in another AZ). Set false for a test cluster, and the chart falls
    back to the in-cluster pod with no other configuration change.
  EOT
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type. BMC stores coordination state, not bulk data, so the smallest current-generation node is usually enough."
  type        = string
  default     = "cache.t4g.small"
}

variable "namespace" {
  description = "Namespace BMC is installed into. Must match global.namespace in the chart -- the redis-service alias is created here, so the two have to agree."
  type        = string
  default     = "bmc"
}
