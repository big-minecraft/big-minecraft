# ---------------------------------------------------------------------- EFS --
#
# The ReadWriteMany half of the storage contract. BMC mounts one deployment's
# game volume into the game pod, an SFTP pod and a file-edit pod at the same
# time, so a ReadWriteOnce class is not a cheaper option -- it is a broken one.

resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs"
  description = "NFS from the EKS nodes to the BMC EFS filesystem"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.cluster_name}-efs" })
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_nodes" {
  security_group_id = aws_security_group.efs.id
  description       = "NFS from cluster nodes"

  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

resource "aws_efs_file_system" "bmc" {
  creation_token  = "${var.cluster_name}-shared"
  encrypted       = true
  throughput_mode = var.efs_throughput_mode

  # Game worlds are read and written constantly by a running server. Moving
  # them to Infrequent Access would add first-byte latency to chunk loads, so
  # no lifecycle policy is set here on purpose.

  tags = merge(var.tags, { Name = "${var.cluster_name}-shared" })
}

# One per AZ. A pod in an AZ with no mount target cannot mount the filesystem
# at all, which surfaces as a pod stuck in ContainerCreating on some nodes and
# not others.
resource "aws_efs_mount_target" "bmc" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.bmc.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# --------------------------------------------------------------- classes ----

# Name must match global.storage.classes.shared.name in profiles/eks.yaml.
resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"

  # efs-ap == dynamic provisioning via access points. The driver's other mode
  # provisions nothing: PVCs stay Pending forever and look exactly like a slow
  # cluster. The preflight shared-storage probe schedules two pods against one
  # claim, so it catches this in about 90 seconds.
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.bmc.id
    directoryPerms   = "700"
    # The chart runs game containers with fsGroup 1000.
    uid = "1000"
    gid = "1000"
  }

  depends_on = [aws_efs_mount_target.bmc]
}

# Name must match global.storage.classes.database.name in profiles/eks.yaml.
#
# EKS ships a gp2 class marked default. This one is deliberately NOT marked
# default: the profile names both classes explicitly, and two defaults is a
# configuration error the API server will not warn you about.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  # The databases want their volume created in the AZ where the pod actually
  # lands, not the other way round.
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}
