variable "subscription_id" {
  description = "Azure subscription to build in. Leave empty to use ARM_SUBSCRIPTION_ID from the environment."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region. Must be one that offers availability zones if node_zones is non-empty."
  type        = string
  default     = "eastus"
}

variable "cluster_name" {
  description = "AKS cluster name. Also used as the prefix for most resources."
  type        = string
  default     = "bmc"
}

variable "resource_group_name" {
  description = "Resource group to create. Everything this layer builds goes in it, so destroying the group destroys the cluster."
  type        = string
  default     = ""
}

variable "kubernetes_version" {
  description = "Kubernetes version. Empty tracks the region's AKS default, which is what most installs want."
  type        = string
  default     = ""
}

variable "sku_tier" {
  description = <<-EOT
    Control plane tier. "Free" has no API server SLA and is fine for testing.
    "Standard" buys a 99.95% SLA and a control plane that scales past a handful
    of nodes -- what a real network wants.
  EOT
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

# ------------------------------------------------------------- networking --

variable "vnet_cidr" {
  description = "Address space for the virtual network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_subnet_cidr" {
  description = "Subnet the nodes sit in. Only nodes take addresses from it -- pods are on an overlay -- so it does not need to be large."
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "Overlay range for pod addresses. Never routed on the VNet, so it only has to avoid colliding with networks the cluster talks to."
  type        = string
  default     = "10.244.0.0/16"
}

variable "services_cidr" {
  description = "ClusterIP range. Must not overlap the VNet or the pod overlay."
  type        = string
  default     = "10.2.0.0/16"
}

variable "api_server_authorized_cidrs" {
  description = "Who may reach the Kubernetes API. Empty means anywhere, which is the AKS default."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- capacity --

variable "node_vm_size" {
  description = <<-EOT
    VM size for the node pool. Minecraft is single-threaded per server and
    latency-sensitive, so clock speed matters more than core count.

    Availability varies by subscription, not just by region -- a size can be
    NotAvailableForSubscription somewhere it plainly exists. Confirm before
    applying, and note the zones it reports:

      az vm list-skus --location <region> --resource-type virtualMachines \
        --query "[?name=='<size>'].{Name:name,Zones:locationInfo[0].zones}" -o table

    An empty result means the size is restricted for you; pass --all to see why.
  EOT
  type        = string
  default     = "Standard_D4s_v5"
}

variable "node_min_count" {
  description = "Minimum nodes in the pool. Spread across node_zones."
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Maximum nodes the autoscaler may add. The ceiling on how far a network can grow."
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "OS disk per node, in GB. Container images live here, and so does each instance's pulled artifact -- game pods fetch into an emptyDir, which is backed by this disk."
  type        = number
  default     = 50
}

variable "node_zones" {
  description = <<-EOT
    Availability zones to spread nodes across. Empty by default because zone
    support is a property of the SKU *and* the subscription, not just the
    region: a size the subscription cannot use in zones fails the cluster
    create outright with AvailabilityZoneNotSupported, reporting the supported
    zones as ''. Set ["1","2","3"] once you have confirmed the size you chose
    offers them -- see node_vm_size for the command.
  EOT
  type        = list(string)
  default     = []
}

variable "node_spot" {
  description = <<-EOT
    Add a spot node pool. Spot VMs are far cheaper and can be reclaimed with 30
    seconds' notice, restarting every Minecraft server on the node.

    It scales from zero and shares node_max_count as its ceiling. Spot draws on
    a separate regional quota that is often tiny -- 3 vCPU on a trial account,
    less than one 4-vCPU node -- so check before relying on it:

      az vm list-usage --location <region> \
        --query "[?contains(localName,'Low-priority')].{Name:localName,Used:currentValue,Limit:limit}" -o table
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource this layer creates."
  type        = map(string)
  default = {
    managed-by = "opentofu"
    project    = "bmc"
  }
}
