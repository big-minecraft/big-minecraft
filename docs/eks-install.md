# Installing BMC on Amazon EKS

End-to-end guide for a fresh cluster: infrastructure, install, DNS, and the
things that fail in ways the error message does not explain.

---

## How the two halves fit together

Two tools, one seam.

```
terraform/eks/      builds the cluster and everything under it
    │
    │   profiles/eks.yaml  ← the contract between them
    ▼
task install        installs BMC onto that cluster
```

`profiles/eks.yaml` states how EKS satisfies BMC's capability contract. The
Terraform layer's job is to make those statements true, which makes the handoff
testable rather than aspirational:

```bash
tofu apply                    # build the infrastructure
task preflight PROFILE=eks    # acceptance test -- probes behaviour, not vendor names
```

The rule that decides who owns what:

> **Terraform owns only what requires cloud credentials or references a cloud
> resource ID. helmfile owns every other in-cluster install.**

| Terraform | helmfile |
|---|---|
| VPC, NAT, subnets and their discovery tags | cert-manager |
| EKS control plane, managed node group | ingress-nginx |
| EBS + EFS CSI drivers, IRSA roles | MetalLB (off for this profile) |
| `efs-sc` and `gp3` storage classes | Traefik (off for this profile) |
| AWS Load Balancer Controller | the `big-minecraft` release |
| Karpenter, its NodePool and EC2NodeClass | |
| The ingress load balancer's security group | |

Only two things here break the "no in-cluster installs" line, and both do so
because they cannot be expressed without an AWS resource ID: the load balancer
controller needs an IRSA role ARN, and `efs-sc` needs the EFS filesystem ID.

**cert-manager and ingress-nginx are deliberately not installed by Terraform.**
`helmfile.yaml` installs them, gated on profile values. Two owners for one
release means the first `helmfile apply` fights Terraform over the CRDs.

---

## Prerequisites

| Tool | Purpose |
|---|---|
| `tofu` or `terraform` (≥ 1.6) | the infrastructure layer |
| `aws` CLI, authenticated | Terraform and `aws eks get-token` |
| `kubectl`, `helm`, `helmfile` | the install layer |
| `task`, `yq` | the task runner and its value merging |

On macOS:

```bash
brew install kubectl helm helmfile yq go-task/tap/go-task opentofu awscli
```

Linux install commands are in the [README](../README.md#prerequisites-local).
Authenticate before building anything:

```bash
aws configure
```

Then confirm the whole set, cloud tooling included:

```bash
task verify PROFILE=eks
```

The cluster-connection check at the end fails until a cluster exists; the tool
checks above it still report.

`terraform` and `tofu` are interchangeable throughout; nothing in `terraform/eks/`
uses syntax specific to either.

---

## 1. Build the infrastructure

```bash
cd terraform/eks
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
tofu init
tofu apply
```

Budget 15–20 minutes. The EKS control plane alone takes 9–12.

Two settings deserve a decision rather than a default:

- **`cluster_name`** — the default is `bmc`. If you also run a bare-metal
  cluster whose kube context is called `bmc`, pick something else (`bmc-eks`).
  Two contexts with confusable names is how you install over production.
- **`file_session_allowed_cidrs`** — defaults to `0.0.0.0/0` so SFTP works out
  of the box. See [Security posture](#security-posture).

> **Values in `terraform.tfvars` override variable defaults.** If a setting
> appears there, editing the default in `variables.tf` does nothing — `tofu`
> reports "0 changes" and the fix looks like it failed. Edit `terraform.tfvars`.

---

## 2. Point kubectl at the cluster

```bash
aws eks update-kubeconfig --region <region> --name <cluster>
kubectl config current-context     # must be the arn:aws:eks:... one
```

Everything from here targets whatever context is current, silently.
`task secrets:generate` and `task install` do not ask.

---

## 3. Configure

```bash
cd ..
task config:init PROFILE=eks
$EDITOR charts/bmc-chart/values.custom.yaml
task validate PROFILE=eks
```

`config:init` starts from `values.example-eks.yaml`. Three fields are marked
`CHANGE THIS`: `certManager.email`, `panel.panelHost`, and `ingress.host` — the
last two must match, or the issued certificate will not match the address the
panel is served on.

Everything else — storage classes, edge types, ingress class, load balancer
annotations — comes from `profiles/eks.yaml`. Restating any of it in
`values.custom.yaml` is how the two drift apart, and the copy here wins.

**There is exactly one active config file.** To point this checkout at a
different cluster, park the current one rather than keeping two:

```bash
mkdir -p backups && mv charts/bmc-chart/values.custom.yaml backups/values.custom.<name>.yaml
task config:init PROFILE=<other-profile>
```

---

## 4. Install

```bash
task secrets:generate      # SAVE THE OUTPUT -- especially the invite code
task install PROFILE=eks
```

`install` runs verify → preflight → validate → secrets:check → dependencies
(ingress-nginx, cert-manager) → wait-for-webhooks → the BMC chart.

Preflight is the real gate. It schedules two pods against one RWX claim,
provisions a LoadBalancer Service, and checks pod egress — behaviour, not
vendor names. If it passes, the chart will install.

---

## 5. DNS

**You do not get an IP.** Both edges are NLBs, which give you a hostname that
resolves to rotating addresses. Never pin an A record to what `dig` returns
today.

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'   # panel

kubectl get svc proxy-lb -n bmc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'   # game
```

| Record | Type | Target |
|---|---|---|
| `panel.yourdomain.com` | CNAME | ingress-nginx hostname |
| `play.yourdomain.com` | CNAME | proxy-lb hostname |

The panel host must equal `ingress.host` / `panel.panelHost`. At a zone apex,
DNS forbids CNAME — use a Route 53 ALIAS A-record, or a subdomain.

Java players connect to `play.yourdomain.com` on the default 25565. Bedrock is
UDP 19132 and clients do not discover it — players enter address and port.

### If you use Cloudflare, turn the proxy OFF

Both records must be **DNS only** (grey cloud).

- **The game record cannot work proxied at all.** Cloudflare's proxy carries
  only HTTP/HTTPS on standard ports. Minecraft on 25565 and Bedrock on 19132
  will not traverse it (Spectrum aside), and it looks like "can't connect".
- **A proxied panel record breaks TLS on a deep subdomain.** Cloudflare's
  Universal SSL covers `example.com` and `*.example.com` — *one* level.
  `panel.eks.example.com` is two, so Cloudflare terminates TLS with no
  certificate for that name and aborts the handshake:
  `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`.
- **It also blocks issuance.** "Always Use HTTPS" 308-redirects
  `/.well-known/acme-challenge/` to a URL whose handshake fails, so Let's
  Encrypt cannot read the token and the challenge sits `pending`.

Keeping Cloudflare in front of the panel means Advanced Certificate Manager for
the deeper subdomain, SSL mode Full (strict), and cert-manager switched to
DNS-01. Since the game edge must bypass Cloudflare regardless, grey-clouding
both is simpler.

---

## 6. Verify

```bash
kubectl get pods -n bmc
kubectl get certificate -n bmc          # READY True once DNS resolves
curl -sI https://panel.yourdomain.com   # 200, valid cert
task sftp:info                          # after opening a file session
```

**A fresh cluster has an empty EFS filesystem**, so the proxy will crash-loop
with `Jar file not found!` until you upload the Velocity jar. That is the
bootstrap step, and it is what file sessions are for. The plugin download
(`Plugin downloaded successfully`) is separate and works on its own.

---

## File sessions (SFTP)

Sessions are reached through ingress-nginx TCP passthrough, **not** a
per-session load balancer.

```
panelHost:31400  →  ingress NLB listener  →  ingress-nginx tcp-services
                                          →  Service sftp-slot-31400
                                          →  the session's SFTP pod
```

The panel allocates one SFTP port per **deployment** from 31400 upward
(`MIN_SFTP_PORT_RANGE`), and never moves it. So the mapping is static: port
31400 always routes to whichever deployment holds 31400, and the file-session
chart names its Service after the port rather than the session.

Why not a load balancer per session:

| | per-session NLB | TCP passthrough |
|---|---|---|
| Extra cost | $16.43/mo per session, 1h minimum | **$0** |
| Ready in | ~4 min (provision + DNS + health checks) | **~20 s** |
| Panel change | required | **none** |

It also makes the panel's existing `sftp://<panelHost>:<sftpPort>` address
correct, because `panelHost` resolves to the ingress load balancer, which now
listens on exactly that port.

Connect with host `panel.yourdomain.com` (no `sftp://` prefix — FileZilla
treats the whole string as a hostname), the port the panel shows, username
`<deployment>_user`, and the password from the panel.

Three values must agree across three files:

| Value | Files |
|---|---|
| port range start | `MIN_SFTP_PORT_RANGE` (panel), `sftpPassthrough.minPort`, `sftp_passthrough_min_port` |
| port count | `sftpPassthrough.portCount`, `sftp_passthrough_port_count` |
| security group name | `aws-load-balancer-security-groups` annotation, `ingress_lb_security_group_name` |

`portCount` is bounded by the NLB's 50-listener limit.

---

## Security posture

**SFTP is public by default.** `file_session_allowed_cidrs = ["0.0.0.0/0"]`
means an open session is reachable by anyone with the address. The only thing
in the way is the shared SFTP password from `bmc-secrets` — identical for every
deployment, and not rotated between sessions, so one leak is durable and total.

Narrowing it is a one-line change and the obvious first hardening step:

```hcl
file_session_allowed_cidrs = ["203.0.113.4/32"]
```

An empty list creates no rule at all, which closes the ports entirely.

The ingress load balancer's security group is Terraform-managed rather than
controller-managed, because `loadBalancerSourceRanges` applies to a whole
Service and this one carries both the panel (port 80 must stay open to the
internet for ACME HTTP-01) and the SFTP block (which should not be). Per-port
rules require owning the group.

---

## Cost

Fixed monthly, us-east-1 list prices, 2 × m6i.xlarge:

| Resource | Monthly |
|---|---|
| EKS control plane | $73 |
| 2 × m6i.xlarge | $280 |
| NAT gateway | $33 |
| 2 × NLB (ingress + game) | $33 |
| EBS gp3, 50 GiB | $4 |
| **Fixed total** | **~$423** |

Variable on top: data transfer out (~$0.09/GB after 100 GB free — this is the
one that scales with players, roughly 500 GB/mo for 20 concurrent), NAT data
processing, NLB LCUs, EFS storage as worlds grow, and Karpenter nodes under
load.

**Biggest lever:** EC2 is two thirds of the fixed cost. A 1-year Compute
Savings Plan takes ~27–30% off and still covers Karpenter's nodes. Moving to
`m7g.xlarge` (Graviton3) is ~15% cheaper *and* faster per core — all BMC images
are `linux/amd64, linux/arm64`, so it is viable, but it needs both
`node_instance_types` **and** the Karpenter NodePool's `kubernetes.io/arch`
requirement changed. Changing only one is a silent no-op.

---

## Node autoscaling

The managed node group is a floor. It runs what must exist before any
autoscaler can — Karpenter itself, CoreDNS, the load balancer controller — and
Karpenter provisions everything above it.

This matters more here than for a typical app: the GameServer operator already
scales game server *pods* by player count, so with a fixed node count those
pods go `Pending` under exactly the load you wanted to absorb.

**Consolidation is set to `WhenEmpty` deliberately.** The tempting
`WhenEmptyOrUnderutilized` evicts running pods to pack nodes tighter — here
that means terminating live Minecraft servers with players connected. The usual
escape hatch is the `karpenter.sh/do-not-disrupt` annotation, and it is **not
available**: the `GameServer` CRD exposes no `annotations` or `podAnnotations`
field, so nothing can mark a game pod immovable until `bmc-manager` adds that
passthrough.

`karpenter_expire_after` (720h) replaces nodes to keep AMIs patched — also a
planned disruption. `"Never"` opts out.

---

## Troubleshooting

### Karpenter starts, never becomes ready, exits code 2 with no logs

The `eks-pod-identity-agent` addon is missing. Karpenter authenticates via EKS
Pod Identity, and the *association* existing is not enough — the agent
daemonset is what serves `http://169.254.170.23/v1/credentials`. Without it
Karpenter blocks fetching credentials, fails its health probes, and is killed
before it logs anything.

```bash
aws eks list-addons --cluster-name <cluster>   # eks-pod-identity-agent must be listed
```

### Connections hang about two times in three

NLB cross-zone load balancing. An NLB spans every subnet it is given — three
AZs here — and publishes one IP per AZ in DNS. With cross-zone disabled (the
AWS default) only an AZ holding a healthy target serves traffic, but its IP
stays in DNS regardless. Backends rarely occupy every AZ, so clients
round-robin onto an IP with nothing behind it.

`profiles/eks.yaml` sets `load_balancing.cross_zone.enabled=true` on all three
edges. To confirm:

```bash
aws elbv2 describe-load-balancer-attributes --load-balancer-arn <arn> \
  --query "Attributes[?Key=='load_balancing.cross_zone.enabled']"
```

Diagnose by testing each IP separately — if one connects and the others time
out, this is it.

### `ssh_init: nodename nor servname provided`

DNS for a load balancer that is still `provisioning`. AWS publishes the record
only once it is `active`, ~3 minutes. Then targets must pass health checks,
about another minute.

```bash
aws elbv2 wait load-balancer-available --names <name>
aws elbv2 wait target-in-service --target-group-arn <arn>
```

### A hostname resolves with `dig` but not in a browser or `curl`

macOS caches DNS in `mDNSResponder`, which `curl` and browsers use and `dig`
bypasses. After changing a record:

```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

Chrome also caches certificate errors — `chrome://net-internals/#dns`.

### Certificate stays `False`, challenge `pending`

```bash
kubectl describe challenge -n bmc
```

`failed to perform self check` with a DNS error means the record does not
resolve yet, or resolves somewhere that is not your ingress — see the
Cloudflare section. cert-manager retries on its own; no need to poke it.

### `error: failed to create secret namespaces "bmc" not found`

Fixed in `generate-secrets.sh`, which now creates the namespace. The underlying
ordering: the namespace is normally made by helmfile during `task install`, but
`install` refuses to start until the secret exists. On a fresh cluster that is
a deadlock.

### Preflight fails on `IngressClass 'nginx' not found`

Fixed in `preflight.sh`. On EKS the class arrives from our own helmfile
release, two steps *after* preflight runs, so a missing class is a warning when
`global.ingressNginx.install` is true — the same treatment cert-manager already
had. It still fails hard when nothing will install a controller.

---

## Teardown

```bash
helmfile destroy        # FIRST
cd terraform/eks && tofu destroy
```

The other order hangs. Kubernetes-created NLBs leave ENIs in the subnets, and
Terraform cannot delete a VPC out from under them — it fails after about twenty
minutes.

---

## Known limitations

- **Node root volumes are 20 GiB, not the configured 50.** The EKS module
  ignores `disk_size` when it builds a custom launch template, which it does by
  default; `block_device_mappings` is the fix. Large JDK images can fill it,
  producing image-pull failures and disk-pressure evictions that look like
  random pod churn.
- **The SFTP password is shared and static.** Same for every deployment, not
  rotated per session. Per-session credentials would be a panel change.
- **The panel's Service-name convention is duplicated.** `bmc-panel`
  reconstructs `sftp-<deployment>-<first 8 of session id>-service` from the
  convention in `pulumiDeploymentService`; both must change together.
- **Adding a helmfile release needs a matching line in `Taskfile.yml`.**
  `task deploy` selects releases by name and helmfile only walks `needs:` with
  `--include-needs`, so a release added to one file and not the other is
  silently never installed.
