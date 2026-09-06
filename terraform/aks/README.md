# BMC on AKS — infrastructure layer

Creates the resource group, virtual network and AKS cluster that BMC runs on.
It stops at the cluster: the ingress controller, cert-manager, datastores,
panel and manager are installed by helmfile on top.

Full walkthrough: [`docs/aks-install.md`](../../docs/aks-install.md).

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
tofu init
tofu apply
tofu output next_steps
```

## What it builds

| Resource | Notes |
|---|---|
| Resource group | Everything lives here, so deleting it is a complete teardown |
| Virtual network + subnet | Nodes only; pods are on an overlay |
| AKS cluster | System-assigned identity, Workload Identity enabled |
| Node pool | Autoscaling, spread across availability zones |
| Spot pool | Only when `node_spot = true` — AKS will not make the system pool spot |

AKS also creates its own **node resource group**, named
`MC_<group>_<cluster>_<region>`, holding the scale set, disks and public IPs.
Terraform does not manage it; it is created and deleted with the cluster.

## What it deliberately does not build

- **No NAT gateway.** Outbound goes through the standard load balancer, which
  is the AKS default and needs no extra resource. Swap `outbound_type` if you
  want a dedicated egress address.
- **No storage classes.** `managed-csi` and `azurefile-csi` are built into
  AKS. Unlike GKE — where Filestore's 1 TiB minimum forces an in-cluster NFS
  server — Azure Files bills per GB, so it backs ReadWriteMany directly.
- **No load balancer controller.** AKS ships one.

## Networking

Azure CNI in **overlay** mode. Pods draw from `pods_cidr`, which is never
routed on the VNet, so the node subnet only has to be large enough for nodes.
The classic non-overlay mode gives every pod a real subnet address and
exhausts a subnet long before it exhausts the nodes.

`services_cidr` must not overlap the VNet or the pod overlay. `dns_service_ip`
is derived from it automatically.

## Teardown

```bash
task teardown PROFILE=aks
task teardown:verify PROFILE=aks
```

Run from the repository root, not from this directory.
