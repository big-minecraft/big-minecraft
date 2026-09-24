# Prerequisites
BMC requires a few pieces of prerequisite software to assist with the installation process. It also requires a proper server install environment. This documentation page will help you ensure you meet both of these requirements.

## CLI Tools
In order to continue with the installation process, a set of CLI tools need to be installed to your local system.
To see the current status of these tools on your system, run:
```sh
task verify
```
If any of these tools aren't installed, the command will link you to instructions for how to install them.

## Cluster

Because BMC sits on top of the Kubernetes orchestration layer, a [cluster](https://en.wikipedia.org/wiki/Computer_cluster) is needed to install it.

This cluster must meet the following requirements:

| Requirement | Condition |
|---|---|
| Kubernetes **1.26+** | Always |
| A `ReadWriteOnce` storage class | Always |
| A `ReadWriteMany`  storage class | **Only if you run persistent deployments** |
| An `IngressClass` | Always |
| A `LoadBalancer` implementation | Always |
| Outbound internet egress from pods | Always |

Because installing a cluster with these requirements is non-trivial, BMC ships with a cluster installation system.
You will be guided through the process of using this system later in the docs.