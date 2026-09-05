variable "project_id" {
  description = "GCP project to build in."
  type        = string
}

variable "region" {
  description = "Region for the cluster and its network."
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE cluster name, also the prefix for most resources."
  type        = string
  default     = "bmc-gke"
}

variable "kubernetes_version" {
  description = <<-EOT
    Minimum control plane version, or "" to let the release channel decide.

    Empty is the default and usually the right answer. The REGULAR channel
    always offers something current, whereas a pinned floor goes stale silently:
    GKE retires versions, and an apply months later fails with
    `No valid versions with the prefix "1.31" found` -- against a cluster
    resource that has nothing wrong with it.

    BMC needs >= 1.26 regardless, because the game edge is a single Service
    carrying both TCP and UDP and MixedProtocolLBService only went GA there.
    Every current channel is far past that. `task preflight PROFILE=gke` checks
    the real server version once the cluster exists, which is the check that
    actually matters.

    To see what a region offers:
      gcloud container get-server-config --region <region>
  EOT
  type        = string
  default     = ""

  validation {
    condition = (
      var.kubernetes_version == "" ||
      tonumber(split(".", var.kubernetes_version)[1]) >= 26
    )
    error_message = "BMC needs Kubernetes >= 1.26 for a mixed TCP+UDP LoadBalancer Service."
  }
}

# ------------------------------------------------------------------ network --

variable "subnet_cidr" {
  description = "Primary range for the nodes."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for pods. VPC-native clusters give every pod a real address, so this wants room."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for Services."
  type        = string
  default     = "10.30.0.0/20"
}

variable "private_nodes" {
  description = <<-EOT
    Put nodes on private addresses, reached outbound through Cloud NAT.

    Cloud NAT is billed per hour per gateway plus per GB processed, and BMC
    needs egress: the proxy entrypoint downloads bmc-velocity.jar from GitHub on
    every pod start, so private nodes without NAT crash-loop at boot.

    false gives nodes public IPs and skips the NAT charge, at the cost of a
    larger attack surface.
  EOT
  type        = bool
  default     = true
}

# -------------------------------------------------------------------- nodes --

variable "node_machine_type" {
  description = "Machine type for the node pool. Minecraft is single-threaded per server and latency-sensitive, so clock speed matters more than core count."
  type        = string
  default     = "n2-standard-4"
}

variable "node_min_count" {
  description = "Minimum nodes per zone. GKE's own cluster autoscaler handles growth -- there is no Karpenter equivalent to install here."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum nodes per zone."
  type        = number
  default     = 3
}

variable "node_disk_size" {
  description = "Boot disk per node, in GB. Game data lives on the shared volume, but container images (JDK images are large) live here."
  type        = number
  default     = 50
}

variable "node_disk_type" {
  description = "Boot disk type. pd-balanced is the sane default; pd-standard is cheaper and much slower."
  type        = string
  default     = "pd-balanced"
}

variable "node_spot" {
  description = <<-EOT
    Use Spot VMs for the node pool.

    Roughly 60-90% cheaper, and preemptible with a 30-second notice: every
    Minecraft server on a reclaimed node restarts mid-session. Reasonable for a
    test cluster, rarely for players.
  EOT
  type        = bool
  default     = false
}

# ------------------------------------------------------------------ access --

variable "master_authorized_cidrs" {
  description = "Who may reach the Kubernetes API. Defaults to the whole internet, which is worth narrowing to your operators."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "labels" {
  description = "Labels applied to everything that takes them."
  type        = map(string)
  default = {
    project    = "big-minecraft"
    managed-by = "opentofu"
  }
}

# -------------------------------------------------------------- HA redis ----

variable "enable_ha_redis" {
  description = <<-EOT
    Provision Memorystore (STANDARD_HA) and point redis-service at it, instead
    of running the single in-cluster Redis pod.

    On by default because Redis is the one component whose loss stops scaling
    cluster-wide, and the in-cluster default has no failover.

    Costs roughly $35/month for a 1 GB STANDARD_HA instance. Set false for a
    test cluster, and the chart falls back to the in-cluster pod with no other
    configuration change.
  EOT
  type        = bool
  default     = true
}

variable "redis_memory_gb" {
  description = "Memorystore instance size. BMC stores coordination state, not bulk data, so the 1 GB minimum is usually enough."
  type        = number
  default     = 1
}

variable "namespace" {
  description = "Namespace BMC is installed into. Must match global.namespace in the chart -- the redis-service alias is created here, so the two have to agree."
  type        = string
  default     = "bmc"
}
