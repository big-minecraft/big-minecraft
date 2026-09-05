# Installing BMC on Google Kubernetes Engine

End-to-end guide for a fresh cluster. The shape mirrors
[the EKS guide](eks-install.md); this covers what is different, and GKE is
meaningfully simpler.

---

## How the two halves fit together

```
terraform/gke/      builds the network, the cluster and its node pool
    │
    │   profiles/gke.yaml  ← the contract between them
    ▼
task install        installs BMC onto that cluster
```

`profiles/gke.yaml` states how GKE satisfies BMC's capability contract. The
Terraform layer's job is to make those statements true:

```bash
tofu apply                    # build the infrastructure
task preflight PROFILE=gke    # acceptance test -- probes behaviour, not vendor names
```

Same ownership rule as everywhere else:

> **Terraform owns only what requires cloud credentials or references a cloud
> resource ID. helmfile owns every other in-cluster install.**

| Terraform | helmfile |
|---|---|
| VPC, subnet and its secondary ranges | NFS server (ReadWriteMany storage) |
| Cloud Router + NAT, when nodes are private | ingress-nginx |
| GKE cluster and its autoscaling node pool | cert-manager |
| | MetalLB, Traefik (off for this profile) |
| | the `big-minecraft` release |

**Nothing here breaks the "no in-cluster installs" line.** Unlike the EKS layer,
Terraform creates no Kubernetes objects at all — GKE provides the storage
classes and the load balancer controller itself.

### What GKE gives you that EKS makes you assemble

| | EKS | GKE |
|---|---|---|
| Node autoscaling | Karpenter: Helm release, IAM role, SQS queue, CRDs | a field on the node pool |
| LoadBalancer Services | install the AWS Load Balancer Controller | built in |
| Block storage class | create it, plus the EBS CSI addon and its IRSA role | `standard-rwo`, built in |
| Pod identity | IRSA, plus the `eks-pod-identity-agent` addon | Workload Identity, on |
| Load balancer address | a hostname; needs cross-zone enabling per Service | an IP; regional already |

The GKE root module is about a third the size as a result.

---

## Prerequisites

| Tool | Purpose |
|---|---|
| `tofu` or `terraform` (≥ 1.6) | the infrastructure layer |
| `gcloud`, authenticated | credentials and `get-credentials` |
| `gke-gcloud-auth-plugin` | kubectl cannot authenticate to GKE without it |
| `kubectl`, `helm`, `helmfile` | the install layer |
| `task`, `yq` | the task runner and its value merging |

On macOS:

```bash
brew install kubectl helm helmfile yq go-task/tap/go-task opentofu
brew install --cask gcloud-cli    # includes gke-gcloud-auth-plugin
```

With a standalone Google Cloud SDK install rather than Homebrew, the plugin is
a separate component:

```bash
gcloud components install gke-gcloud-auth-plugin
```

Linux install commands are in the [README](../README.md#prerequisites-local).

### Authenticate — both stores

These write **two separate credential stores**, and you need both:

```bash
gcloud auth login                        # gcloud commands use this
gcloud auth application-default login    # Terraform uses this
```

This catches people out because the failure is silent and asymmetric. `gcloud`
keeps working from the first store while Terraform fails on the second, so
everything looks authenticated right up until:

```
Error: Error setting access_token
  with data.google_client_config.default
  oauth2: "invalid_grant" "Bad Request"
```

That is Application Default Credentials, not your gcloud login. The ADC file
also **expires quietly** — it sits at
`~/.config/gcloud/application_default_credentials.json` holding a refresh token
that can be revoked or aged out months before you notice. Re-running
`gcloud auth application-default login` fixes it.

`task verify PROFILE=gke` tests this properly, by minting a token rather than
trusting the file's existence.

Then confirm the whole set, cloud tooling included:

```bash
task verify PROFILE=gke
```

The cluster-connection check at the end fails until a cluster exists; the tool
checks above it still report.

The Compute Engine and Kubernetes Engine APIs are enabled by Terraform
(`services.tf`), so there is nothing to do by hand. If you would rather enable
them ahead of time, or the project is locked down enough that Terraform cannot:

```bash
gcloud services enable compute.googleapis.com container.googleapis.com
```

---

## 1. Build the infrastructure

```bash
cd terraform/gke
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars      # project_id is required and has no default
tofu init
tofu apply
```

Budget 10–15 minutes.

Decisions worth making rather than accepting:

- **`private_nodes`** (default `true`) — private nodes reach the internet
  through Cloud NAT, billed hourly plus per GB. It is not optional while the
  proxy entrypoint downloads its plugin jar from GitHub on every pod start:
  no egress means every proxy pod crash-loops at boot. Setting `false` gives
  nodes public IPs and skips the NAT charge, with a larger attack surface.
- **`node_min_count` / `node_max_count`** are **per zone**, and a regional
  cluster spans three. `node_min_count = 1` means three nodes.
- **`node_spot`** — 60–90% cheaper, reclaimed on 30 seconds' notice, which
  restarts every Minecraft server on that node. Fine for a test cluster.

> **Values in `terraform.tfvars` override variable defaults.** If a setting
> appears there, editing the default in `variables.tf` does nothing — `tofu`
> reports "0 changes" and the fix looks like it failed. Edit `terraform.tfvars`.

---

## 2. Point kubectl at the cluster

```bash
gcloud container clusters get-credentials <cluster> --region <region> --project <project>
kubectl config current-context
```

Everything from here targets whatever context is current, silently.
`task secrets:generate` and `task install` do not ask.

---

## 3. Configure

```bash
cd ../..
task config:init PROFILE=gke
$EDITOR charts/bmc-chart/values.custom.yaml
task validate PROFILE=gke
```

Three fields are marked `CHANGE THIS`: `certManager.email`, `panel.panelHost`,
and `ingress.host` — the last two must match, or the issued certificate will
not match the address the panel is served on.

Everything else comes from `profiles/gke.yaml`. Restating any of it in
`values.custom.yaml` is how the two drift apart, and the copy here wins.

---

## 4. Install

```bash
task secrets:generate      # SAVE THE OUTPUT -- especially the invite code
task install PROFILE=gke
```

`install` runs verify → preflight → validate → secrets:check → dependencies
(NFS server, ingress-nginx, cert-manager) → wait-for-webhooks → the BMC chart.

The NFS server installs first and must be running before the chart, because
every game deployment claims against the class it creates, and a PVC naming a
class that does not exist stays `Pending` indefinitely rather than failing.

---

## 5. DNS

**GCP load balancers hand out an IP**, not a hostname, so these are A records —
the opposite of EKS.

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # panel

kubectl get svc proxy-lb -n bmc \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # game
```

| Record | Type | Target |
|---|---|---|
| `panel.yourdomain.com` | A | ingress-nginx IP |
| `play.yourdomain.com` | A | proxy-lb IP |

Because they are IPs, a bare apex domain works without the ALIAS-record
workaround AWS needs. To keep the game address stable across cluster rebuilds,
reserve a regional static address and set `global.edge.game.loadBalancerIP` —
GCP honours that field, unlike AWS.

**If you use Cloudflare, both records must be DNS only (grey cloud).** The game
record cannot work proxied at all — Cloudflare carries only HTTP/HTTPS on
standard ports, so 25565 and 19132 will not traverse it. A proxied panel record
breaks TLS on a two-level subdomain and blocks ACME HTTP-01. The
[EKS guide](eks-install.md#if-you-use-cloudflare-turn-the-proxy-off) covers the
detail; it is identical here.

---

## 6. Verify

```bash
kubectl get pods -n bmc
kubectl get pods -n nfs                  # the NFS server must be Running
kubectl get certificate -n bmc           # READY True once DNS resolves
curl -sI https://panel.yourdomain.com    # 200, valid cert
task sftp:info                           # after opening a file session
```

**Check Bedrock explicitly.** See
[mixed TCP+UDP](#the-one-thing-to-verify-yourself) below — preflight does not
cover it.

**A fresh cluster has an empty shared volume**, so the proxy crash-loops with
`Jar file not found!` until you upload the Velocity jar. That is the bootstrap
step, and it is what file sessions are for.

---

## ReadWriteMany without Filestore

BMC needs a ReadWriteMany class: the panel mounts a deployment's game volume
into a file-edit pod and an SFTP pod at the same time as the running server.

**Filestore is GCP's managed answer and it is priced wrong for this.** The
smallest instance is 1 TiB at roughly $200/month whether you store a terabyte or
six kilobytes — more than the rest of a small cluster costs, and unlike EFS it
does not scale down.

So this profile runs an NFS server in the cluster instead
(`nfs-server-provisioner`), backed by an ordinary `standard-rwo` disk sized by
`global.nfsServer.size` (default 100 GiB, about $10/month). It exports the
`nfs` ReadWriteMany class that `storage.classes.shared.name` points at.

**The trade is availability, not durability.** One NFS server pod serves every
deployment's game data, so while it restarts, mounts hang. The data itself is on
a normal PVC and survives the pod. Two settings soften the failure mode:

- `reclaimPolicy: Retain` — deleting a PVC does not take the world with it.
- `mountOptions: [hard, nfsvers=4.1]` — clients block and retry across a server
  restart rather than returning I/O errors into a running Minecraft server.

If you outgrow this, the upgrade path is Filestore with the CSI driver addon
(`gcp_filestore_csi_driver_config`, currently disabled in `gke.tf`) and pointing
`storage.classes.shared.name` at its class. Nothing else changes.

---

## The one thing to verify yourself

**Mixed TCP + UDP on a single Service** is the riskiest assumption in this
profile. The game edge carries TCP 25565 (Java) and UDP 19132 (Bedrock) on one
Service, which needs `MixedProtocolLBService` (GA in 1.26) and a
backend-service-based L4 load balancer — requested by the
`cloud.google.com/l4-rbs: "enabled"` annotation. The older target-pool
implementation cannot do it.

**Preflight will not catch a failure here**: its LoadBalancer probe provisions a
TCP-only Service, so it passes whether or not mixed protocol works. After
installing, confirm both listeners exist:

```bash
kubectl get svc proxy-lb -n bmc -o jsonpath='{.spec.ports[*].protocol}'   # expect TCP UDP
gcloud compute forwarding-rules list --filter="name~bmc"
```

Then actually connect a Bedrock client. If UDP is missing, the fallback is a
second Service for Bedrock alone, with its own address — a chart change, since
today one Service carries both.

---

## Cost

Rough monthly, us-central1, 3 nodes (one per zone) of `n2-standard-4`:

| Resource | Monthly |
|---|---|
| GKE cluster management fee | $73 |
| 3 × n2-standard-4 | $415 |
| Cloud NAT gateway | $32 |
| 2 × L4 load balancer | ~$36 |
| Boot disks + NFS disk (250 GiB pd-balanced) | $25 |
| **Fixed total** | **~$580** |

Levers, roughly in order of value:

- **`node_min_count = 1` is per zone.** A regional cluster runs three. A zonal
  cluster (set `location` to a zone) cuts the node bill by two thirds and gives
  up zone redundancy — reasonable for a first cluster.
- **Spot VMs** (`node_spot = true`) take 60–90% off the node bill, with
  reclamation restarting servers.
- **Committed use discounts** take ~37% off the node bill for a 1-year
  commitment, with no operational downside.
- **`private_nodes = false`** removes the NAT gateway (~$32/mo) at the cost of
  public node IPs.
- **Filestore would have added ~$200/mo** on its own. That is why it is off.

---

## Teardown

```bash
task teardown PROFILE=gke
```

Removes the Helm releases first — so GKE deletes its load balancers and frees
their forwarding rules — then destroys the infrastructure. The reverse order
leaves resources holding the network and the destroy fails late.

The cluster sets `deletion_protection = false` deliberately; GKE defaults it on,
which turns `tofu destroy` into a confusing failure.

Note that `task teardown:verify` checks **AWS only**. For GCP:

```bash
gcloud container clusters list
gcloud compute instances list
gcloud compute forwarding-rules list
gcloud compute disks list
gcloud compute routers nats list --router <cluster>-router --region <region>
```

---

## Troubleshooting

### `Error setting access_token ... oauth2: "invalid_grant" "Bad Request"`

Application Default Credentials are missing or expired. See
[Authenticate — both stores](#authenticate--both-stores): `gcloud auth login`
and `gcloud auth application-default login` are different, and Terraform uses
the second. Confirm with:

```bash
gcloud auth application-default print-access-token
```

An error there means the credentials are stale regardless of what
`gcloud auth list` shows. Nothing is created when this fails, so it is a clean
retry after re-authenticating.

### `Error 403: Compute Engine API has not been used in project ... SERVICE_DISABLED`

The required APIs were not enabled. Terraform now enables them itself, so this
should only appear on a project where it lacks permission to do so, or if
`services.tf` was removed. Enable them by hand and retry:

```bash
gcloud services enable compute.googleapis.com container.googleapis.com --project <project>
```

Activation is asynchronous — wait a minute before retrying. Nothing is created
when this fails, so it is a clean retry.

### `gke-gcloud-auth-plugin was not found or is not executable`

kubectl has no built-in GCP authentication since Kubernetes 1.26; it shells out
to this plugin for a token. `gcloud container clusters get-credentials` writes a
kubeconfig referencing it whether or not it is installed, so the error arrives
from kubectl *after* the cluster is built rather than from gcloud.

```bash
gcloud components install gke-gcloud-auth-plugin
```

Homebrew installs disable the component manager; there the plugin comes with
`brew install --cask gcloud-cli`. `task verify PROFILE=gke` checks for it.

### `No valid versions with the prefix "1.xx" found`

A pinned `kubernetes_version` that GKE has since retired. The default is now
empty, which lets the release channel choose; clear any pin in
`terraform.tfvars`. To see what a region offers:

```bash
gcloud container get-server-config --region <region>
```

### Node counts are per zone

`node_min_count = 1` on a regional cluster is three nodes, and three times the
bill you estimated. Set `location` to a zone rather than a region for a zonal
cluster, or divide the counts by three.

---

## Known limitations

- **Mixed TCP+UDP is unverified on a live cluster.** See above.
- **The NFS server is a single point of failure** for game data availability.
  Durability is unaffected.
- **`teardown:verify` is AWS-only.** The GCP equivalents are listed above.
- **`node_min_count`/`node_max_count` are per zone**, which is easy to misread
  as a cluster total and bill three times what you expected.
