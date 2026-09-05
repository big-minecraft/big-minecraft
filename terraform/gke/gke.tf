# The cluster.
#
# Notably smaller than the EKS equivalent, because GKE bundles what AWS makes
# you assemble: the cluster autoscaler is a field on the node pool rather than
# Karpenter plus IAM plus CRDs, the PD CSI driver is built in rather than an
# addon with its own IRSA role, and Services of type LoadBalancer work without
# installing a controller first.

resource "google_container_cluster" "bmc" {
  name     = var.cluster_name
  location = var.region

  # The default node pool is removed immediately; the real one is below. This
  # is the documented way to manage node pools as separate resources.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.bmc.id
  subnetwork = google_compute_subnetwork.bmc.id

  # Omitted when empty, which lets the release channel pick. See the variable.
  min_master_version = var.kubernetes_version != "" ? var.kubernetes_version : null

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  dynamic "private_cluster_config" {
    for_each = var.private_nodes ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false
      master_ipv4_cidr_block  = "172.16.0.0/28"
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block = cidr_blocks.value
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Deletion protection defaults on and turns `tofu destroy` into a confusing
  # failure. BMC clusters are meant to be rebuildable.
  deletion_protection = false

  # Filestore CSI is deliberately NOT enabled. Its smallest instance is 1 TiB
  # at roughly $200/month whether you store a terabyte or nothing, which is
  # more than the rest of this cluster costs. ReadWriteMany comes from an
  # in-cluster NFS server backed by an ordinary disk instead -- installed by
  # helmfile, see global.nfsServer in profiles/gke.yaml.
  addons_config {
    gcp_filestore_csi_driver_config {
      enabled = false
    }
    # PD CSI is on by default and provides the standard-rwo class the databases
    # use; naming it here documents the dependency.
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  resource_labels = var.labels

  depends_on = [google_project_service.required]
}

resource "google_container_node_pool" "bmc" {
  name     = "${var.cluster_name}-nodes"
  cluster  = google_container_cluster.bmc.id
  location = var.region

  # Per zone. A regional cluster spans three zones, so this is 3x the count.
  initial_node_count = var.node_min_count

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size
    disk_type    = var.node_disk_type
    spot         = var.node_spot

    # Least privilege: the nodes need to pull images and write logs, nothing
    # more. Anything in-cluster that needs GCP APIs uses Workload Identity.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = var.labels
  }

  lifecycle {
    # The autoscaler owns the count once the pool exists.
    ignore_changes = [initial_node_count]
  }
}
