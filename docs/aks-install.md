# Installing BMC on Azure Kubernetes Service

Two layers, built in order:

1. **The cluster** — `terraform/aks/` creates the resource group, virtual
   network and AKS cluster with an autoscaling node pool.
2. **BMC itself** — helmfile installs the ingress controller, cert-manager,
   the datastores, the panel and the manager on top.

The seam between them is `profiles/aks.yaml`, which states how AKS satisfies
BMC's capability contract. Nothing in the chart layer is Azure-specific; the
profile is where that knowledge lives.

## How the two halves fit together

The contract, and who satisfies it on AKS:

| Capability | Satisfied by | Installed by |
|---|---|---|
| ReadWriteOnce storage | `managed-csi` (Azure Disk) | built into AKS |
| ReadWriteMany storage | `azurefile-csi` (Azure Files) | built into AKS |
| LoadBalancer Services | AKS service controller | built into AKS |
| IngressClass | ingress-nginx | helmfile |
| Pod egress | outbound via the standard load balancer | Terraform |
| TLS certificates | cert-manager + Let's Encrypt | helmfile |

### What AKS gives you that EKS makes you assemble

The AKS Terraform layer is much smaller than the EKS one, and not because it
does less:

- **Autoscaling is a field on the node pool**, not Karpenter plus an IAM role,
  plus a queue, plus CRDs.
- **Both CSI drivers are built in.** No addon with its own identity to wire up.
- **LoadBalancer works out of the box.** No load balancer controller to install
  before a Service can get an address.
- **ReadWriteMany has no minimum size.** Azure Files bills for what you use.

That last point is worth dwelling on, because it is the one place AKS beats
both other clouds — see below.

## ReadWriteMany without a 1 TiB bill

GKE needs an in-cluster NFS server because Filestore's smallest instance is
1 TiB at roughly $200/month whether you store a terabyte or nothing. Azure
Files has no such minimum, so `profiles/aks.yaml` uses `azurefile-csi`
directly and sets `nfsServer.install: false`. One less pod to run, one less
thing to restart.

The tradeoff is that `azurefile-csi` is **SMB, not a POSIX filesystem**. File
locking and permissions are emulated. Only persistent deployments touch it —
every other deployment type pulls artifacts into a pod-local `emptyDir` — so
the blast radius is small. If a server misbehaves on it, switch to the same
NFS server GKE uses:

```yaml
# values.custom.yaml
global:
  nfsServer:
    install: true
    backingStorageClass: "managed-csi"
  storage:
    classes:
      persistent:
        name: "nfs"
```

If you run no persistent deployments at all, set
`global.storage.persistentDeployments: false` and neither is needed.

## Prerequisites

- `az`, logged in with a subscription selected
- `tofu` (or `terraform`) ≥ 1.6
- `kubectl`, `helm`, `helmfile`, `yq`
- A domain you control, for the panel

Check everything at once:

```bash
task verify PROFILE=aks
```

### Authenticate

```bash
az login
az account set --subscription "<subscription name or id>"
```

`azurerm` 4 requires a subscription to be selected explicitly. An account with
several subscriptions selects none by default, and Terraform fails at plan
time rather than at login — which is why `task verify` checks
`az account show` rather than just that `az` exists.

To avoid putting the subscription id in a file, export it instead:

```bash
export ARM_SUBSCRIPTION_ID=$(az account show --query id --output tsv)
```

`subscription_id` in `terraform.tfvars` may then be left empty.

## 1. Build the infrastructure

```bash
cd terraform/aks
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
tofu init
tofu apply
```

Takes roughly 5–10 minutes. When it finishes, `tofu output next_steps` prints
the rest of this document in short form.

Check your regional vCPU quota before asking for a large cluster — this is the
ceiling that actually stops a scale-up:

```bash
az vm list-usage --location eastus \
  --query "[?contains(name.value, 'cores')].{Name:localName,Used:currentValue,Limit:limit}" \
  --output table
```

Quotas are per subscription and per region, and cannot be raised from
Terraform.

## 2. Point kubectl at the cluster

```bash
az aks get-credentials --resource-group bmc-aks-rg --name bmc-aks
```

## 3. Configure

```bash
task config:init PROFILE=aks
```

That writes `charts/bmc-chart/values.custom.yaml` from the AKS example. Set at
minimum:

- `global.certManager.email`
- `global.panel.panelHost`
- `global.ingress.host` — must match `panelHost`

## 4. Install

```bash
task preflight PROFILE=aks
task secrets:generate
task install PROFILE=aks
```

`preflight` is the acceptance test for the Terraform layer: it provisions a
real LoadBalancer, a real PVC of each access mode, and checks pod egress. Run
it before `install`, not after — it fails in seconds where a bad install fails
in minutes.

## 5. DNS

Azure load balancers hand out an **IP address**, not a hostname, so these are
**A records**, not CNAMEs.

```bash
# panel
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# game edge
kubectl get svc proxy-lb -n bmc \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Point `panelHost` at the first and your game domain at the second. The
certificate is issued once the panel record resolves.

## 6. Verify

```bash
kubectl get pods -n bmc
kubectl get certificate -n bmc           # READY True once DNS resolves
curl -sI https://panel.yourdomain.com    # 200, valid cert
task sftp:info                           # after opening a file session
```

**A fresh cluster has an empty shared volume**, so the proxy crash-loops until
you upload the Velocity jar through a file session. That is the bootstrap
step, and it is what file sessions are for.

## The one thing to verify yourself

**Bedrock on UDP 19132.**

The game edge carries TCP 25565 and UDP 19132 on one Service. That needs
`MixedProtocolLBService` (GA in Kubernetes 1.26) and the standard load
balancer SKU, which `terraform/aks` sets. It should work — but the preflight
LoadBalancer probe only provisions TCP, so **it will not catch a failure
here.**

After installing, connect a Bedrock client, or:

```bash
IP=$(kubectl get svc proxy-lb -n bmc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
nc -vzu "$IP" 19132
```

If Bedrock is dead but Java works, split them onto two Services rather than
fighting the mixed-protocol path.

## Cost

The rough shape of a small cluster, at `Standard_D4s_v5`:

| Item | Notes |
|---|---|
| Control plane | Free tier has no SLA; Standard adds a monthly charge |
| Nodes | The bulk of the bill; scales with `node_min_count` |
| Load balancers | Two: the ingress and the game edge |
| Managed disks | One per node, plus one per database PVC |
| Azure Files | Only if you run persistent deployments; billed per GB used |
| Egress | Per GB out; players pull world data, so this is not zero |

`sku_tier = "Free"` is fine for testing. A real network wants `"Standard"` for
the API server SLA.

## Teardown

```bash
task teardown PROFILE=aks
task teardown:verify PROFILE=aks
```

`teardown:verify` lists anything still billable. Every line empty means
nothing is accruing charges.

Two Azure-specific notes:

- AKS creates a **second, node resource group** named
  `MC_<group>_<cluster>_<region>` holding the scale set, disks and public IPs.
  It is deleted with the cluster. If it survives, the destroy did not finish.
- `teardown:verify` lists the **whole subscription**, not just BMC's resource
  group, so unrelated resources show up too. Read it as "here is everything
  that bills", not "here is what leaked".

## Troubleshooting

### `building AzureRM Client: could not configure AzureCliAuthorizer`

`az` is not logged in, or no subscription is selected.

```bash
az login
az account set --subscription "<name or id>"
```

### `Code="InvalidParameter"` — zones not supported in location

The region has no availability zones. Set `node_zones = []` in
`terraform.tfvars`.

### PVCs on `azurefile-csi` stay Pending

Azure Files provisioning creates a storage account on first use and is slower
than disk. Give it a couple of minutes. If it persists, check the events:

```bash
kubectl describe pvc <name> -n bmc
```

A `SubscriptionNotRegistered` error means the `Microsoft.Storage` provider is
not registered:

```bash
az provider register --namespace Microsoft.Storage
```

### Nodes will not scale past a certain count

Regional vCPU quota, not the node pool maximum. Check with the `az vm
list-usage` command above; `node_max_count` cannot exceed what the
subscription permits.

## Known limitations

- **Mixed TCP/UDP on one Service is untested by preflight.** See above.
- **`azurefile-csi` is SMB.** Fine for most server files; see the swap to NFS
  above if a particular server dislikes it.
- **The node pool is one size.** There is no Karpenter equivalent choosing
  instance types per workload the way the EKS layer does.
