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

- kubectl, helm, helmfile
- [yq](https://github.com/mikefarah/yq) (mikefarah/yq, not the Python one)
- [Task](https://taskfile.dev)
- A domain pointing at your cluster's entrypoint

---

## Profiles

A **profile** describes how one *kind* of cluster satisfies the requirements
above. It is data, not code — adding support for a new environment means adding
a YAML file, never editing a template.

| Profile | For |
|---|---|
| `baremetal-metallb` | Bare metal / k3s with MetalLB + Longhorn (the default) |
| `generic` | Any other conformant cluster — managed Kubernetes, VMs, k3d |

Provider-specific load balancer settings are supplied as
`global.edge.game.annotations`, which are passed through to the Service
verbatim. See `charts/bmc-chart/values.example.yaml` for AWS/GCP/Azure examples.

---

## Quick Start

```bash
# 1. Check your tooling and cluster connection
task verify

# 2. Create your config
task config:init
#    then edit charts/bmc-chart/values.custom.yaml

# 3. Check the cluster can actually run BMC
task preflight PROFILE=baremetal-metallb

# 4. Generate secrets -- SAVE THE OUTPUT, especially the invite code
task secrets:generate

# 5. Install
task install PROFILE=baremetal-metallb
```

Access the panel at your configured domain and use the invite code from step 4.

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
task verify           # Verify local prerequisites
task preflight        # Verify the cluster satisfies the capability contract
task conformance      # Preflight, plus render every profile
task config:init      # Initialize configuration
task validate         # Check required config values are set
task secrets:generate # Generate secrets
task diff             # Show what an apply would change
task install          # Complete installation
task upgrade          # Upgrade an existing installation
task uninstall        # Remove installation
task help             # Show all tasks
```

All cluster-facing tasks accept `PROFILE=<name>`, defaulting to
`baremetal-metallb`.

---

## Support

For issues, questions, or contributions:
- GitHub Issues - Report bugs or request features
- Pull Requests - Contributions welcome
