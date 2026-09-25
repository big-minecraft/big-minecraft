# Installing BMC on Azure AKS

The following steps will guide you through installing a BMC-compatible environment onto a new Azure Kubernetes Service cluster.
In your terminal set your local terminal to use AKS as the installation profile.

```sh
export PROFILE="aks"
```

Ensure you use this terminal session for the rest of the installation process, or make sure to repeat this step if a new session is opened.

## Prerequisites

Once again, ensure you have the proper CLI tools installed on your local system.
```sh
task verify
```
If any of them aren't installed, follow the provided guide to do so.

Also ensure `az` is logged in **with a subscription selected**. An account with several subscriptions
selects none by default, and the build then fails partway through rather than at login:

```sh
az login
az account set --subscription "<subscription name or id>"
```

`task verify` checks the selected subscription rather than just the binary, so re-run it once you have
logged in. The cluster-connection check at the end fails until the cluster exists; everything above it
still reports.

## Configuration

To generate the cluster config file, run the following command:

```sh
task cluster:init
```

This will create the file `config/infrastructure/aks.tfvars`.
Open this file with your text editor of choice.

Fill out the config according to the guide written in the file's comments.
A few things to note:

- **`subscription_id`** — leave it empty to use the subscription you selected above, exported as
  `ARM_SUBSCRIPTION_ID`, and keep the id out of a file:
  ```sh
  export ARM_SUBSCRIPTION_ID=$(az account show --query id --output tsv)
  ```
- **`node_vm_size`** — availability is per **subscription**, not just per region: a size can be
  restricted for you somewhere it plainly exists, and AKS then fails the create with a confusing
  `AvailabilityZoneNotSupported`. The comments in the file include the command that confirms a size
  before you build with it.
- **`node_min_count` / `node_max_count`** — the whole pool, not per zone. Check they fit your regional
  vCPU quota, which is commonly capped at 10 on a trial subscription — two 4-vCPU nodes and no more.
- **`sku_tier`** — `Free` has no API server SLA and is fine for testing. A real network wants
  `Standard`.

## Installation

Run the following command again to build the cluster:
```sh
task cluster
```

This process may take upwards of **10 minutes**.

Finally, switch your `kubectl` context to the cluster the build just created.
```sh
az aks get-credentials --resource-group <cluster_name>-rg --name <cluster_name>
```

Running `tofu output configure_kubectl` in `terraform/aks` prints this command filled in with what you
actually built. Add `--overwrite-existing` if you have built this cluster before, or `az` keeps the stale
entry already in your kubeconfig and every later command talks to a cluster that no longer exists.

## Verification

To verify installation was successful and that the generated cluster conforms to BMC's requirements, run the following command:
```sh
task preflight
```

## Cost

Rough fixed monthly, eastus list prices, two `Standard_D4s_v5` nodes:

| Resource | Monthly |
|---|---|
| Control plane (`sku_tier = "Free"`) | $0 |
| 2 × Standard_D4s_v5 | $280 |
| 2 × standard load balancer (panel + game) | ~$37 |
| Managed OS disks, 2 × 50 GiB | ~$19 |
| **Fixed total** | **~$335** |

Variable on top: egress per GB as players pull world data, Azure Files billed per GB used (only if you
run persistent deployments), and the nodes the pool adds under load. `sku_tier = "Standard"` adds a
monthly charge for the API server SLA.

Levers, roughly in order of value:

- **Nodes are the whole bill here**, since the Free control plane is free. A 1-year reserved instance
  takes roughly 40% off them.
- **Spot VMs** (`node_spot = true`) are far cheaper, in a second pool that scales from zero, and
  reclamation restarts every server on the node. Spot has its own regional quota, often far smaller than
  the standard one.
