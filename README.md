# Big Minecraft (BMC) - Kubernetes Orchestrator

A complete Kubernetes-based orchestration platform for managing Minecraft server networks at scale.

## Features

- **Multi-Deployment Management** - Run multiple Minecraft servers with different configurations
- **Auto-Scaling** - Scalable deployments that distribute players automatically
- **Web Panel** - Full-featured management interface with real-time monitoring
- **File Management** - Built-in SFTP and web-based file browser
- **Database Management** - Integrated MariaDB and MongoDB with GUI management
- **User Management** - Multi-user support with roles and 2FA authentication
- **Real-time Metrics** - Live CPU, memory, and player count monitoring

---

## Cluster requirements

BMC does not care which provider you use, but it does require a cluster with
specific capabilities. `task preflight` verifies all of them.

| Requirement | Why |
|---|---|
| Kubernetes **1.26+** | The game entrypoint is one Service carrying both TCP and UDP (`MixedProtocolLBService`, GA in 1.26) |
| A **ReadWriteMany** storage class, mountable by several pods at once | The panel mounts a deployment's game volume into a file-edit pod and an SFTP pod *while the server is running* |
| A **ReadWriteOnce** storage class | MariaDB and MongoDB. Use block storage, not a network filesystem |
| An **IngressClass** | Serves the web panel |
| A **LoadBalancer** implementation | The game entrypoint. MetalLB on bare metal, the provider's controller on cloud |
| **Outbound internet egress from pods** | The proxy downloads its plugin jar from GitHub on every start |

Only the game entrypoint is internet-facing. Everything else — panel, databases,
Redis, Prometheus — is ClusterIP.

### Prerequisites (local)

Every profile needs these four, plus [Task](https://taskfile.dev) to run the
commands in this README:

| Tool | Why |
|---|---|
| `kubectl` | talks to the cluster |
| `helm` | renders and installs the charts |
| `helmfile` | orders the releases and their dependencies |
| `yq` | **mikefarah/yq**, not the Python one — the Python build emits JSON and quotes string values, which silently corrupts every merged value |

Cloud profiles need two more: OpenTofu (or Terraform) to build the cluster, and
your provider's CLI, authenticated.

**macOS**

```bash
brew install kubectl helm helmfile yq go-task/tap/go-task

brew install opentofu          # cloud profiles
brew install awscli            # eks
brew install --cask gcloud-cli # gke
```

**Linux (Debian/Ubuntu)**

```bash
# kubectl
curl -fsSLo /usr/share/keyrings/kubernetes.gpg https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key
echo "deb [signed-by=/usr/share/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update && sudo apt install -y kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# helmfile, yq, task -- release binaries
curl -fsSL https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz | sudo tar xz -C /usr/local/bin helmfile
sudo curl -fsSLo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin

# cloud profiles
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method deb   # opentofu
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o a.zip && unzip -q a.zip && sudo ./aws/install   # eks
curl -fsSL https://sdk.cloud.google.com | bash   # gke
```

Then check what you have. Pass the profile so the cloud tooling is checked too:

```bash
task verify PROFILE=eks
```

The tool checks print first and the cluster connection is checked last, so this
is still useful before any cluster exists — it will report every tool, then fail
on the connection. That last failure is expected until you have built or joined
a cluster.

You also need a domain you control, pointing at your cluster's entrypoint.

**Authenticate your provider CLI** before building a cloud cluster:

```bash
aws configure          # eks

gcloud auth login                        # gke -- gcloud commands use this
gcloud auth application-default login    # gke -- Terraform uses this
```

On GCP those are two separate credential stores. `gcloud` keeps working from
the first while Terraform fails on the second, so a half-authenticated machine
looks fine until `tofu apply` dies with `invalid_grant`. The ADC store also
expires quietly. `task verify PROFILE=gke` tests it by minting a token.

---

## Profiles

A **profile** describes how one *kind* of cluster satisfies the requirements
above. It is data, not code — adding support for a new environment means adding
a YAML file, never editing a template.

| Profile | For |
|---|---|
| `baremetal-metallb` | Bare metal / k3s with MetalLB + Longhorn (the default) — see [docs/baremetal-install.md](docs/baremetal-install.md) |
| `eks` | Amazon EKS — see [`terraform/eks/`](terraform/eks/) to build the cluster |
| `gke` | Google Kubernetes Engine — see [`terraform/gke/`](terraform/gke/) |
| `generic` | Any other conformant cluster — managed Kubernetes, VMs, k3d |

Provider-specific load balancer settings are supplied as
`global.edge.game.annotations`, which are passed through to the Service
verbatim. See `charts/bmc-chart/values.example.yaml` for AWS/GCP/Azure examples.

---

## Quick Start

```bash
# 1. Check your tooling and cluster connection
task verify

# 2. Create your config, pre-filled for your profile
task config:init PROFILE=baremetal-metallb
#    then edit charts/bmc-chart/values.custom.yaml -- every line marked CHANGE THIS

# 3. Check the cluster can actually run BMC
task preflight PROFILE=baremetal-metallb

# 4. Generate secrets -- SAVE THE OUTPUT, especially the invite code
task secrets:generate

# 5. Install
task install PROFILE=baremetal-metallb
```

Access the panel at your configured domain and use the invite code from step 4.

There is exactly one active config file, `charts/bmc-chart/values.custom.yaml`,
and the profile is what makes it environment-appropriate. `config:init` starts
it from `values.example-<profile>.yaml` when that profile has a template, and
from the generic `values.example.yaml` otherwise.

To point this checkout at a different cluster, park the current config rather
than keeping two:

```bash
mkdir -p backups && mv charts/bmc-chart/values.custom.yaml backups/values.custom.<name>.yaml
task config:init PROFILE=<other-profile>
```

### On bare metal

Full guide: **[docs/baremetal-install.md](docs/baremetal-install.md)** — k3s,
MetalLB, Longhorn, port forwarding, and the failure modes specific to owning
every layer yourself. There is no Terraform layer for this profile.

### On a cloud

The cluster itself is built by the OpenTofu/Terraform layer under
[`terraform/`](terraform/), one root module per cloud. Build it first; the
steps above are then identical apart from the profile name.

**EKS** — full guide: **[docs/eks-install.md](docs/eks-install.md)**

```bash
cd terraform/eks && cp terraform.tfvars.example terraform.tfvars && tofu apply
aws eks update-kubeconfig --region <region> --name <cluster>
cd ../.. && task config:init PROFILE=eks
task preflight PROFILE=eks && task secrets:generate && task install PROFILE=eks
```

**GKE** — full guide: **[docs/gke-install.md](docs/gke-install.md)**

```bash
cd terraform/gke && cp terraform.tfvars.example terraform.tfvars && tofu apply
gcloud container clusters get-credentials <cluster> --region <region>
cd ../.. && task config:init PROFILE=gke
task preflight PROFILE=gke && task secrets:generate && task install PROFILE=gke
```

To tear either down completely:

```bash
task teardown PROFILE=<eks|gke>
```

---

## Local testing

A disposable BMC on k3d, safe to run alongside a real cluster:

```bash
task test:up        # k3d cluster + an RWX (NFS) storage class
task test:install   # preflight + install (uses the published images)
task test:status
task test:panel     # http://localhost:8080  (invite code in .local-test/secrets.txt)
task test:down

task test:build     # OPTIONAL - build panel/manager from source, import
```

`task test:all` runs the whole sequence, building only if the published images
cannot run on your node.

Two deliberate safety properties: it writes its own kubeconfig to
`.local-test/kubeconfig` so **your default kubectl context is never switched**,
and it uses `charts/bmc-chart/values.local.yaml` so **`values.custom.yaml` is
never read or written**.

**Runtime charts ship with the chart.** `charts/bmc-chart/files/chart-templates/`
and `files/default-values/` are rendered into a ConfigMap and mounted read-only
into the panel at `/opt/bmc/runtime`. Edit them, re-run `task test:install`, and
the change is live — no push, no clone, no sync step. They consume
`.Values.global.*`, which the same chart defines, so the two halves of that
contract now version together.

**When you need `test:build`.** Both published images are multi-arch
(amd64 + arm64), so `test:install` normally just pulls them and you never need
to build. Build in one case:

- **You are testing panel or manager changes.** Published images run published
  source, not your working tree — the same trap as the old chart-templates
  clone, one layer up.

It is also used automatically if a published image ever lacks a variant for your
node's architecture; `install` then names the offending image and stops, rather
than leaving you at `ImagePullBackOff`. Check with
`docker manifest inspect <image>`, and publish multi-arch with
`docker buildx build --platform linux/amd64,linux/arm64 --push`.

The panel and manager live in **separate repositories**. `build` resolves their
source in this order:

1. `BMC_PANEL_SRC` / `BMC_MANAGER_SRC` — set them once in a gitignored
   `.local-test.env` at the repo root
2. sibling checkouts (`../bmc-panel`, `../../bmc-panel`)
3. a shallow clone into `.local-test/src/` — so this works on a machine that has
   never checked them out, though it then builds *published* source

`BMC_TEST_IMAGES=published` forces the registry images regardless.

---

## Available Tasks

```bash
task verify           # Verify local prerequisites (and cloud CLIs, per profile)
task preflight        # Verify the cluster satisfies the capability contract
task conformance      # Preflight, plus render every profile
task config:init      # Initialize configuration for PROFILE
task validate         # Check required config values are set
task secrets:generate # Generate secrets
task storage          # Install the in-cluster storage provider, if the profile uses one
task diff             # Show what an apply would change
task install          # Complete installation
task upgrade          # Upgrade an existing installation
task sftp:info        # Connection details for open file sessions
task uninstall        # Remove BMC, leaving the cluster
task teardown         # Destroy BMC *and* the cloud infrastructure under it
task teardown:verify  # List cloud resources that would still incur charges
task help             # Show all tasks
```

Local testing has its own set — see [Local testing](#local-testing) above.

All cluster-facing tasks accept `PROFILE=<name>`, defaulting to
`baremetal-metallb`. Everything is driven through `task`; nothing in `scripts/`
is meant to be run directly.

---

## Support

For issues, questions, or contributions:
- GitHub Issues - Report bugs or request features
- Pull Requests - Contributions welcome
