# BMC on EKS -- infrastructure layer

This builds everything *below* BMC: the VPC, the EKS cluster, node groups, the
EFS filesystem behind ReadWriteMany, the CSI drivers, the AWS Load Balancer
Controller, and ingress-nginx.

It does not install BMC. The chart layer (`task install PROFILE=eks`) does that,
and the two halves meet at one file: **`profiles/eks.yaml`**.

## The boundary

`profiles/eks.yaml` states how EKS satisfies BMC's capability contract. This
layer's job is to make those statements true. That makes the handoff testable
rather than aspirational:

```
tofu apply                    # build the infrastructure
task preflight PROFILE=eks    # acceptance test -- probes behaviour, not vendor names
```

Preflight schedules two pods against one RWX claim, provisions a LoadBalancer
Service, and checks pod egress. If it passes, the chart will install.

The rule that decides who owns what:

> **Terraform owns only what requires cloud credentials or references a cloud
> resource ID. helmfile owns every other in-cluster install.**

| Owned here | Owned by `helmfile.yaml` |
|---|---|
| VPC, NAT, subnets and their LB discovery tags | cert-manager |
| EKS control plane, managed node group | ingress-nginx (`IngressClass: nginx`) |
| EBS + EFS CSI drivers, IRSA roles | MetalLB (off for this profile) |
| `efs-sc` and `gp3` storage classes | Traefik (off for this profile) |
| AWS Load Balancer Controller | the `big-minecraft` release |
| Karpenter + its NodePool/EC2NodeClass | |

Only two things here break the "no in-cluster installs" line, and both do so
because they cannot be expressed without an AWS resource ID: the load balancer
controller needs an IRSA role ARN, and the `efs-sc` storage class needs the
filesystem ID.

**cert-manager and ingress-nginx are deliberately not installed here.**
`helmfile.yaml` installs cert-manager whenever `ingress.tls.mode` is
`cluster-issuer`, which this profile sets, and ingress-nginx whenever
`global.ingressNginx.install` is true, which this profile also sets. Two owners
for one release means the first `helmfile apply` fights this layer over the
CRDs.

ingress-nginx does depend on the load balancer controller installed here -- its
Service sits in `<pending>` forever without one. Terraform runs before helmfile,
so that ordering holds without either tool knowing about the other.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit it
tofu init
tofu plan
tofu apply
```

`terraform` and `tofu` are interchangeable throughout; nothing here uses syntax
specific to either.

Then follow the `next_steps` output.

## Three things that cost money, and why

**NAT gateway.** Billed hourly plus per-GB, and not optional: the proxy
entrypoint downloads `bmc-velocity.jar` from GitHub on *every* pod start, so
private nodes with no egress produce proxies that crash-loop at boot. Vendoring
that jar into the image would turn this from a hard requirement into a
nice-to-have. `single_nat_gateway = false` triples the hourly cost and buys
egress that survives an AZ loss.

**One NLB per open file session.** `profiles/eks.yaml` sets
`edge.file.type: LoadBalancer` because on private node subnets a NodePort is
simply unreachable -- sessions would open and then refuse connections. NLBs bill
hourly with a one-hour minimum, so ten short sessions in a day is ten load
balancer hours. The durable fix is ClusterIP plus SFTP proxying through the
panel, which is a panel feature that does not exist yet.

**EFS.** Charged per GB stored with no lifecycle policy set here on purpose --
moving live game worlds to Infrequent Access would add first-byte latency to
chunk loads.

**Karpenter-provisioned nodes.** On-demand EC2, capped by `karpenter_cpu_limit`.
This is the line item that grows with your player count.

## Node autoscaling

The managed node group is a floor, not the whole cluster. It runs what must
exist before any autoscaler can — Karpenter itself, CoreDNS, the load balancer
controller — and Karpenter provisions everything above it.

This matters more here than for a typical app. The GameServer operator already
scales game server *pods* by player count (`scaling.minInstances` /
`maxInstances` / `scaleUpThreshold`). With a fixed node count those pods just go
`Pending` once the group fills, under exactly the load you wanted to absorb.

**Consolidation is deliberately set to `WhenEmpty`.** The tempting setting,
`WhenEmptyOrUnderutilized`, evicts running pods to pack nodes tighter — here
that means terminating live Minecraft servers with players connected to save an
instance-hour. The normal escape hatch is the `karpenter.sh/do-not-disrupt`
annotation on pods that must not move, and it is **not available**: the
`GameServer` CRD exposes no `annotations` or `podAnnotations` field, so nothing
can mark a game pod immovable until `bmc-manager` adds that passthrough. Until
then the conservative policy is the only safe one.

Two other planned disruptions worth knowing about:

- `karpenter_expire_after` (default 720h) replaces nodes to keep AMIs patched.
  Nodes drain, so their game servers restart. `"Never"` opts out and leaves
  patching to you.
- `karpenter_capacity_types` is `["on-demand"]`. Adding `"spot"` saves roughly
  70% and buys a two-minute eviction notice; the interruption queue is wired up
  so the shutdown is graceful, but it is still a shutdown mid-session.

`karpenter_cpu_limit` (default 200 vCPU) is the backstop against a runaway
scale-up billing you for a fleet.

## Security groups and source IPs

Every load balancer in this stack is an ip-target NLB, which preserves the
client's source IP end to end. The node security group therefore sees real
client addresses, not the load balancer's -- so a rule allowing only the VPC
CIDR produces a load balancer that provisions cleanly, passes health checks, and
drops every real connection.

That is why `game_allowed_cidrs`, `file_session_allowed_cidrs` and
`panel_allowed_cidrs` exist here, and why each must be kept in step with the
matching `global.edge.*.sourceRanges` in `values.custom.yaml`. Setting one and
not the other either breaks access or silently leaves a port open.

`file_session_allowed_cidrs` defaults to `0.0.0.0/0` so file sessions work out
of the box. An open session is then reachable by anyone with the address,
guarded only by the shared SFTP password -- which is identical for every
deployment and does not rotate per session. Narrowing it to the addresses you
connect from is a one-line change and the obvious first hardening step.
