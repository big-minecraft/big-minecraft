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
# config/aks.yaml
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
# Creates config/infrastructure/aks.tfvars and stops so you can edit it.
task cluster PROFILE=aks

$EDITOR config/infrastructure/aks.tfvars

# Run it again to build.
task cluster PROFILE=aks
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

Use the resource group and cluster name from your `terraform.tfvars` — with the
defaults in the example that is `bmc-aks-rg` and `bmc-aks`. `tofu output
configure_kubectl` prints the exact command for what you actually built.

```bash
az aks get-credentials --resource-group bmc-aks-rg --name bmc-aks
```

Add `--overwrite-existing` if you have built this cluster before. Without it,
`az` keeps the stale entry already in your kubeconfig and every later command
talks to a cluster that no longer exists.

Confirm what you are pointed at, and that the nodes arrived:

```bash
kubectl config current-context     # should be bmc-aks
kubectl get nodes                  # all Ready
```

Everything from here targets whatever context is current, silently.
`task secrets:generate` and `task install` do not ask.

`terraform/aks` builds a local-account cluster, which kubectl reaches on its
own. If you later enable Entra integration, kubectl needs `kubelogin` on PATH
(`az aks install-cli`) — `az` writes a kubeconfig referencing it whether or not
it is installed, so the failure comes from kubectl, not from `az`.

## 3. Configure

```bash
task config:init PROFILE=aks
```

That writes `config/aks.yaml` from the AKS example. Set at
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

**Azure load balancers hand out an IP**, not a hostname, so these are A
records — the same as GKE, the opposite of EKS.

Both addresses only exist once BMC is installed and the Services have been
assigned. If either command prints nothing, the load balancer is still being
provisioned; give it a minute.

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # panel

kubectl get svc proxy-lb -n bmc \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # game
```

Create these at your DNS provider:

| Record | Type | Target |
|---|---|---|
| `panel.yourdomain.com` | A | ingress-nginx IP |
| `play.yourdomain.com` | A | proxy-lb IP |

`panel.yourdomain.com` must match `global.ingress.host` and
`global.panel.panelHost` exactly, or the certificate will not match the name
the browser asks for.

Because they are IPs, a bare apex domain works without the ALIAS-record
workaround AWS needs.

Check the records resolve before moving on — cert-manager cannot complete the
ACME HTTP-01 challenge until the panel name resolves to the ingress IP from the
public internet:

```bash
dig +short panel.yourdomain.com
dig +short play.yourdomain.com
```

### Keeping the game address stable

By default Azure allocates the game IP dynamically, and it changes if the
Service is recreated — which means every player's server address breaks. To
pin it, create a **static** public IP and set `global.edge.game.loadBalancerIP`
in `config/aks.yaml`; the chart writes it onto the Service.

The address must live in the cluster's **node resource group**, the
`MC_<group>_<cluster>_<region>` one AKS manages, or the load balancer cannot
claim it:

```bash
NODE_RG=$(az aks show --resource-group bmc-aks-rg --name bmc-aks \
  --query nodeResourceGroup --output tsv)

az network public-ip create \
  --resource-group "$NODE_RG" --name bmc-game-ip \
  --sku Standard --allocation-method Static \
  --query publicIp.ipAddress --output tsv
```

Put the printed address in `global.edge.game.loadBalancerIP` and reinstall. It
survives cluster rebuilds only if you also keep the resource group, so for a
truly permanent address create it in your own group instead and add
`service.beta.kubernetes.io/azure-load-balancer-resource-group: <your-group>`
to `global.edge.game.annotations` — the cluster identity needs Network
Contributor on that group.

### If you use Cloudflare, turn the proxy OFF

Both records must be **DNS only** (grey cloud), for the same reasons as on EKS
and GKE:

- **The game record cannot work proxied at all.** Cloudflare's proxy carries
  only HTTP/HTTPS on standard ports, so 25565 and 19132 will not traverse it.
- **A proxied panel record breaks TLS on a deep subdomain**, and blocks the
  ACME HTTP-01 challenge.

The [EKS guide](eks-install.md#if-you-use-cloudflare-turn-the-proxy-off) covers
the detail; it is identical here.

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

### `AvailabilityZoneNotSupported` — "the supported zones ... are ''"

Almost never means the region has no zones. It usually means **the VM size is
not available to your subscription**, so it has no zones *for you* — and the
message reports the empty set rather than the real reason.

Check the size directly:

```bash
az vm list-skus --location eastus --resource-type virtualMachines \
  --query "[?name=='Standard_D4s_v5'].{Name:name,Zones:locationInfo[0].zones}" -o table
```

An empty result means it is restricted. Add `--all` to see why:

```bash
az vm list-skus --location eastus --resource-type virtualMachines --all \
  --query "[?name=='Standard_D4s_v5'].restrictions[].{Type:type,Reason:reasonCode}" -o json
```

`NotAvailableForSubscription` means pick another size. To find one that works:

```bash
az vm list-skus --location eastus --resource-type virtualMachines \
  --query "[?name=='Standard_D4s_v7'].{Name:name,Zones:locationInfo[0].zones}" -o table
```

Newer subscriptions are often offered the **v7** family where v5 is
restricted. Set `node_vm_size` to whatever the check returns, and only set
`node_zones` once that same command shows zones for it.

### Nodes stop scaling well below `node_max_count`

Regional vCPU quota. A trial subscription is commonly capped at **10 total**,
which is two 4-vCPU nodes:

```bash
az vm list-usage --location eastus \
  --query "[?contains(localName,'Total Regional vCPUs')].{Name:localName,Used:currentValue,Limit:limit}" \
  --output table
```

Quota is per subscription and per region and cannot be raised from Terraform.

### `ErrCode_InsufficientVCPUQuota` creating the spot pool

Spot draws on a **separate** regional quota from on-demand, and it is often
tiny — 3 vCPU on a trial account, less than one 4-vCPU node:

```bash
az vm list-usage --location eastus \
  --query "[?contains(localName,'Low-priority')].{Name:localName,Used:currentValue,Limit:limit}" \
  --output table
```

The spot pool scales from zero, so it creates even on a small quota — but it
can only scale as far as that quota allows. If the limit is below one node's
worth of vCPU, spot is unusable at that VM size: pick a smaller size or set
`node_spot = false`.

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

## Known limitations

- **Mixed TCP/UDP on one Service is untested by preflight.** See above.
- **`azurefile-csi` is SMB.** Fine for most server files; see the swap to NFS
  above if a particular server dislikes it.
- **The node pool is one size.** There is no Karpenter equivalent choosing
  instance types per workload the way the EKS layer does.
