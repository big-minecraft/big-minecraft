# Installing BMC on Amazon EKS

The following steps will guide you through installing a BMC-compatible environment onto a new Amazon EKS cluster.
In your terminal set your local terminal to use EKS as the installation profile.

```sh
export PROFILE="eks"
```

Ensure you use this terminal session for the rest of the installation process, or make sure to repeat this step if a new session is opened.

## Prerequisites

Once again, ensure you have the proper CLI tools installed on your local system.
```sh
task verify
```
If any of them aren't installed, follow the provided guide to do so.

Also ensure the AWS CLI is authenticated, since both building the cluster and every later `kubectl` call
depend on those credentials:

```sh
aws configure
```

`task verify` tests the credentials themselves rather than just the binary, so re-run it once you have
logged in. The cluster-connection check at the end fails until the cluster exists; everything above it
still reports.

## Configuration

To generate the cluster config file, run the following command:

```sh
task cluster:init
```

This will create the file `config/infrastructure/eks.tfvars`.
Open this file with your text editor of choice.

Fill out the config according to the guide written in the file's comments.
A few things to note:

- **`region`** and **`cluster_name`** — the name defaults to `bmc`. If you also run a bare-metal
  cluster, pick something distinct (`bmc-eks`); two confusable contexts is how you install over
  production.
- **`node_group_min_size` / `node_group_max_size`** — the managed node group is only the floor. It
  runs what must exist before any autoscaler can, and Karpenter provisions every node above it, up to
  `karpenter_cpu_limit`.
- **`file_session_allowed_cidrs`** — who may reach SFTP file sessions. It defaults to `0.0.0.0/0` so
  sessions work out of the box, and the only thing protecting an open one is the shared SFTP password.
  Narrowing it to the addresses you connect from is the obvious first hardening step.

## Installation

Run the following command again to build the cluster:
```sh
task cluster
```

This process may take upwards of **20 minutes** — the EKS control plane alone accounts for 9–12 of them.

Finally, switch your `kubectl` context to the cluster the build just created.
```sh
aws eks update-kubeconfig --region <region> --name <cluster_name>
```

Running `tofu output configure_kubectl` in `terraform/eks` prints this command filled in with what you
actually built.

## Verification

To verify installation was successful and that the generated cluster conforms to BMC's requirements, run the following command:
```sh
task preflight
```

## Cost

Rough fixed monthly, us-east-1 list prices, two `m6i.xlarge` nodes:

| Resource | Monthly |
|---|---|
| EKS control plane | $73 |
| 2 × m6i.xlarge | $280 |
| NAT gateway | $33 |
| 2 × NLB (panel + game) | $33 |
| EBS gp3 boot volumes | $8 |
| **Fixed total** | **~$430** |

Variable on top: data transfer out (~$0.09/GB, the one that scales with players), NAT data processing,
NLB LCUs, EFS storage as worlds grow, and the nodes Karpenter adds under load.

**Biggest lever:** EC2 is two thirds of the fixed cost. A 1-year Compute Savings Plan takes ~27–30% off
and still covers Karpenter's nodes. Setting `single_nat_gateway = false` triples the NAT charge for
per-AZ egress redundancy.
