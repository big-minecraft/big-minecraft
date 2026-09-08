# BMC bare-metal cluster layer

The bare-metal counterpart of `terraform/<cloud>/`. It builds a cluster that
satisfies `profiles/baremetal.yaml` and stops there; helmfile installs BMC on
top.

Full walkthrough: [`docs/baremetal-install.md`](../docs/baremetal-install.md).

## Usage

```bash
task cluster PROFILE=baremetal   # creates the inventory, stops so you can edit
$EDITOR config/infrastructure/baremetal.inventory.yml
task cluster PROFILE=baremetal   # builds
```

Run it from the repository root, not from this directory.

## What it builds

| Step | Why it is here and not left manual |
|---|---|
| `open-iscsi`, `nfs-common`, `iscsid` on every node | Longhorn backs RWX with an internal NFS share. A node missing `nfs-common` mounts RWO fine and fails only when a file session opens a RWX volume — long after install, looking like a BMC bug |
| k3s, `--disable servicelb` | Klipper competes with MetalLB for LoadBalancer Services; the symptom is an address that does not route |
| Longhorn | Provides both storage classes the profile names. The cloud layers create their storage classes too, so the layer that prepares the cluster owns storage on every profile |
| kubeconfig merged into `~/.kube/config` | What `az`, `gcloud` and `aws` all do, so bare metal behaves like the cloud profiles |

## Topology

`k3s_servers` is the control plane; `k3s_agents` are workers. The playbook
refuses an even number of servers — embedded etcd needs an odd count to hold
quorum, and two servers is strictly worse than one.

Three nodes **in total** is what the HA datastore modes want, so their quorum
members land in separate failure domains. Servers count toward that.

## Physical or virtual

No difference. Ansible needs SSH and sudo; it does not care what the machine
is. There is deliberately no hypervisor provisioning here — if you want VMs
created as well, that belongs in a layer above this one.

## Re-running

Safe. Nodes that already have k3s are skipped, so this is also how you add a
machine to an existing cluster.

## What it does not do

- **No MetalLB.** helmfile installs it, gated on `metallb.installResources`.
- **No OS install, no hypervisor.** You bring reachable machines.
- **No OS install and no hypervisor** — see above. Teardown *is* handled:
  `task teardown PROFILE=baremetal` removes BMC and then runs `uninstall.yml`,
  which runs k3s's own uninstall scripts on every node, clears Longhorn's data
  directory (which those scripts know nothing about), and drops the context
  from your kubeconfig. The machines themselves are left alone.
