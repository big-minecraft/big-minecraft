# Installing BMC on bare-metal

The following steps will guide you through installing a BMC-compatible environment onto a set of local linux machines.
In your terminal set your local terminal to use bare-metal as the installation profile.

```sh
export PROFILE="baremetal"
```

Ensure you use this terminal session for the rest of the installation process, or make sure to repeat this step if a new session is opened.

## Prerequisites

Once again, ensure you have the proper CLI tools installed on your local system.
```sh
task verify
```
If any of them aren't installed, follow the provided guide to do so. 

Also ensure every Linux machine you wish to add to the cluster has an account that:

- uses **the same username** on every machine,
- accepts **the same SSH private key**, and
- can `sudo` **without being prompted for a password**.

If you have not set up SSH keys before, DigitalOcean's
[How to Set Up SSH Keys](https://www.digitalocean.com/community/tutorials/how-to-set-up-ssh-keys-on-ubuntu-22-04)
walks through generating one key and copying it to each machine with
`ssh-copy-id`.

## Configuration

To generate the cluster config file, run the following command:

```sh
task cluster
```

This will create the file `config/infrastructure/baremetal.inventory/yml`.
Open this file with your text editor of choice.

Fill out the config according to the guide written in the file's comments.
One thing to note:

- **`k3s_servers`** — control-plane nodes. One is fine. Three gives a highly
  available control plane with embedded etcd, and the count must be **odd** or
  etcd cannot hold quorum.
- **`k3s_agents`** — workers.

## Installation

Run the following command again to build the cluster:
```sh
task cluster
```

This process may take upwards of **10 minutes**. 

Finally, switch your `kubectl` context to the one our build script just generated.
```sh
kubectl config use-context bmc-baremetal
```

## Verification

To verify installation was successful and that the generated cluster conforms to BMC's requirements, run the following command:
```sh
task prefight
```