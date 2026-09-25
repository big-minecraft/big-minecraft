# Installing BMC on Google GKE

The following steps will guide you through installing a BMC-compatible environment onto a new Google Kubernetes Engine cluster.
In your terminal set your local terminal to use GKE as the installation profile.

```sh
export PROFILE="gke"
```

Ensure you use this terminal session for the rest of the installation process, or make sure to repeat this step if a new session is opened.

## Prerequisites

Once again, ensure you have the proper CLI tools installed on your local system.
```sh
task verify
```
If any of them aren't installed, follow the provided guide to do so.

Also ensure `gcloud` is authenticated. This takes **two** logins, because they write two separate
credential stores and you need both:

```sh
gcloud auth login                        # gcloud commands use this
gcloud auth application-default login    # the build uses this
```

Missing the second one fails silently until the build is already running, with
`oauth2: "invalid_grant" "Bad Request"`. `task verify` tests it properly by minting a token, so re-run it
once you have logged in. The cluster-connection check at the end fails until the cluster exists;
everything above it still reports.

## Configuration

To generate the cluster config file, run the following command:

```sh
task cluster:init
```

This will create the file `config/infrastructure/gke.tfvars`.
Open this file with your text editor of choice.

Fill out the config according to the guide written in the file's comments.
A few things to note:

- **`project_id`** — required, and it has no default. Everything else can be left alone for a first
  cluster.
- **`node_min_count` / `node_max_count`** — these are **per zone**, and the cluster is regional, so it
  spans three. `node_min_count = 1` means three nodes and three times the bill you might have estimated.
- **`private_nodes`** — private nodes reach the internet through Cloud NAT, billed hourly plus per GB.
  Egress is not optional, since the proxy downloads its plugin jar on every pod start. Setting `false`
  gives nodes public IPs and skips the NAT charge, with a larger attack surface.

## Installation

Run the following command again to build the cluster:
```sh
task cluster
```

This process may take upwards of **15 minutes**.

Finally, switch your `kubectl` context to the cluster the build just created.
```sh
gcloud container clusters get-credentials <cluster_name> --region <region> --project <project_id>
```

Running `tofu output configure_kubectl` in `terraform/gke` prints this command filled in with what you
actually built.

## Verification

To verify installation was successful and that the generated cluster conforms to BMC's requirements, run the following command:
```sh
task preflight
```

## Cost

Rough fixed monthly, us-central1 list prices, a regional cluster of three `n2-standard-4` nodes (one per
zone):

| Resource | Monthly |
|---|---|
| GKE cluster management fee | $73 |
| 3 × n2-standard-4 | $415 |
| Cloud NAT gateway | $32 |
| 2 × L4 load balancer (panel + game) | ~$36 |
| Boot disks, 3 × 50 GiB pd-balanced | $15 |
| **Fixed total** | **~$570** |

Variable on top: egress per GB as players pull world data, NAT data processing, the disk backing shared
storage, and the nodes the pool adds under load.

Levers, roughly in order of value:

- **Nodes are three quarters of the fixed cost**, and there are three of them because the counts are per
  zone. A smaller `node_machine_type` scales that line down directly.
- **Spot VMs** (`node_spot = true`) take 60–90% off the node bill, and reclamation restarts every server
  on the node.
- **Committed use discounts** take ~37% off the node bill for a 1-year commitment, with no operational
  downside.
- **`private_nodes = false`** removes the NAT gateway at the cost of public node IPs.
