# Installing BMC on bare metal

For k3s (or any self-managed Kubernetes) with MetalLB and Longhorn. This is the
environment BMC was originally built for, and the one where you own every layer
— which means a few things the cloud guides get for free have to be set up by
hand.

There is no Terraform layer here. Nothing in this repo provisions your machines;
`profiles/baremetal-metallb.yaml` describes what the cluster must already
provide, and `task preflight` checks it.

```
your cluster        you build this -- k3s, MetalLB, Longhorn
    │
    │   profiles/baremetal-metallb.yaml  ← what BMC expects of it
    ▼
task install        installs BMC onto it
```

---

## What the cluster must provide

| Requirement | Supplied by |
|---|---|
| Kubernetes 1.26+ | k3s, or any distribution |
| A **ReadWriteMany** storage class | Longhorn (RWX), or NFS |
| A **ReadWriteOnce** storage class | Longhorn |
| An **IngressClass** | Traefik — k3s installs it by default |
| A **LoadBalancer** implementation | MetalLB, with an address pool you own |
| **Outbound egress from pods** | your network |
| A **public IP** reachable on 25565/tcp and 19132/udp | your network |

`task preflight PROFILE=baremetal-metallb` tests all of it behaviourally.

---

## ReadWriteMany is conditional

Every deployment type except persistent pulls its files from the artifact store
into a pod-local emptyDir, so only one pod ever holds a deployment's volume: the
file session. That needs ReadWriteOnce.

**`nfs-common` is only needed for persistent deployments.** Longhorn's RWX is NFS-backed, and that is the only thing requiring it. An installation with no persistent deployments can set `storage.persistentDeployments` false and skip it on every node.

---

## Prerequisites

On your workstation: `kubectl`, `helm`, `helmfile`, `yq` (mikefarah's), and
`task` — see the [README](../README.md#prerequisites-local) for install
commands. No cloud CLI and no OpenTofu are needed for this profile.

```bash
task verify PROFILE=baremetal-metallb
```

---

## 1. The cluster

k3s is the path of least resistance. On the machine that will be your server:

```bash
curl -sfL https://get.k3s.io | sh -
sudo cat /etc/rancher/k3s/k3s.yaml   # copy to your workstation as ~/.kube/config
```

Replace `127.0.0.1` in that kubeconfig with the machine's reachable address.

**Disable k3s's built-in ServiceLB (Klipper).** It competes with MetalLB for
Services of type LoadBalancer, and the symptom is a Service that gets an
address which does not actually route:

```bash
curl -sfL https://get.k3s.io | sh -s - --disable servicelb
```

Leave Traefik enabled — the profile expects `ingress.className: traefik`, and
k3s installs it into `kube-system`.

Multi-node: run the installer with `K3S_URL` and `K3S_TOKEN` on the other
machines. BMC works on a single node, but see the RWX warning below.

---

## 2. Longhorn (storage)

**Every node needs `open-iscsi`, and every node needs `nfs-common`.** Longhorn's
RWX volumes are NFS-backed internally, so a node missing `nfs-common` mounts
ReadWriteOnce volumes happily and fails only when a file session tries to open —
long after install, in a way that looks like a BMC bug.

```bash
# on EVERY node
sudo apt install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

Then:

```bash
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=300s
```

> **Single-node clusters:** preflight's RWX probe schedules two pods and passes
> when both mount the claim — but on one node that only proves co-located
> access, not real cross-node RWX. It warns about exactly this. A node-local
> class can pass here and fail the moment you add a second node.

---

## 3. MetalLB

Installed by `task install` (`global.metallb.installResources` is true in this
profile), so there is nothing to do by hand. What you must decide is the
**address pool**: one or more IPs on your network that nothing else claims, and
that your router forwards to.

The profile expects a single shared address carrying both the panel and the
game. You will set it in step 5.

> Do not add a presync hook that deletes the MetalLB CRDs. Deleting a CRD
> cascades to its custom resources, so every apply would wipe the
> IPAddressPools — including any your cluster operator manages. `helmfile.yaml.gotmpl`
> carries this warning too.

---

## 4. DNS and ports

Point an A record at your MetalLB address:

| Record | Type | Target |
|---|---|---|
| `panel.yourdomain.com` | A | your MetalLB address |
| `play.yourdomain.com` | A | the same address |

Both can be the same IP. That is the point of the shared-IP annotation the
profile sets — Traefik and the game edge coexist on one address.

Forward these to that address at your router or firewall:

| Port | Protocol | For |
|---|---|---|
| 80 | TCP | ACME HTTP-01 challenges |
| 443 | TCP | the panel |
| 25565 | TCP | Minecraft Java |
| 19132 | UDP | Minecraft Bedrock |
| 31400–31599 | TCP | SFTP file sessions (NodePort range) |

**Port 80 must stay open to the world**, or Let's Encrypt cannot reach the
ingress and the certificate never issues.

**If you use Cloudflare, set both records to DNS only (grey cloud).** The game
record cannot work proxied at all — Cloudflare carries only HTTP/HTTPS on
standard ports. A proxied panel record breaks TLS on a two-level subdomain and
blocks ACME. The
[EKS guide](eks-install.md#if-you-use-cloudflare-turn-the-proxy-off) has the
detail; it applies identically here.

---

## 5. Configure

```bash
task config:init PROFILE=baremetal-metallb
$EDITOR charts/bmc-chart/values.custom.yaml
task validate PROFILE=baremetal-metallb
```

Beyond the usual `certManager.email`, `panel.panelHost` and `ingress.host`
(the last two must match), bare metal needs your address in **two** places:

```yaml
global:
  edge:
    game:
      annotations:
        # The profile supplies allow-shared-ip; only the address is yours.
        metallb.io/loadBalancerIPs: "203.0.113.10"
  metallb:
    ipAddressPool:
      - "203.0.113.10/32"
```

Setting one without the other is the classic mistake: MetalLB has no pool to
allocate from, or allocates an address the Service never asks for. `task
validate` fails when the pool is empty.

**If your cluster already has a ClusterIssuer** (managed by something else), set
`certManager.installClusterIssuer: false` and name it in `clusterIssuerName` —
otherwise BMC creates one and the two fight.

---

## 6. Install

```bash
task secrets:generate      # SAVE THE OUTPUT -- especially the invite code
task install PROFILE=baremetal-metallb
```

`install` runs verify → storage → preflight → validate → secrets:check →
dependencies → wait-for-webhooks → the BMC chart.

Two bare-metal-only things happen inside `task deploy`, both automatic:

- **The MetalLB address pool is applied separately** from the rest of the
  chart. IPAddressPool and L2Advertisement are custom resources, so MetalLB's
  CRDs have to exist before they can be created.
- **k3s's Traefik Service is annotated** with `metallb.io/allow-shared-ip`, so
  the game edge can share Traefik's address. This is idempotent, and skips
  silently if Traefik is not present. Worth knowing: it annotates a Service
  **k3s owns**, so a k3s upgrade can revert it — re-running `task install`
  puts it back.

---

## 7. Verify

```bash
kubectl get pods -n bmc
kubectl get svc proxy-lb -n bmc          # EXTERNAL-IP should be your address
kubectl get certificate -n bmc           # READY True once DNS resolves
curl -sI https://panel.yourdomain.com    # 200
```

**A fresh install has an empty volume**, so the proxy crash-loops with
`Jar file not found!` until you upload a Velocity jar. That is the bootstrap
step, and it is what file sessions are for.

---

## File sessions (SFTP)

Bare metal uses the **NodePort** edge, which is the historical behaviour and
works here for a reason that does not hold on cloud: the MetalLB address lives
on a node, and NodePorts listen on every node IP — so the
`panelHost:<port>` address the panel advertises actually resolves to something
listening.

That is why `edge.file.type` is `NodePort` in this profile and `ClusterIP` on
the cloud profiles, where the panel host resolves to an ingress load balancer
that serves only 80 and 443.

Ports come from the panel's own range, 31400–31599, one per deployment. Forward
that range (or the part you use) at your firewall.

```bash
task sftp:info    # prints the address for any open session
```

---

## Trying it locally first

`task test:all` stands up a disposable k3d cluster with RWX storage, builds the
panel and manager images for your architecture, and installs BMC — without
touching your kubeconfig or `values.custom.yaml`:

```bash
task test:all       # create cluster, build images, install, report
task test:panel     # port-forward the panel to http://localhost:8080
task test:status    # what is running
task test:down      # delete everything
```

The steps are also available individually — `task test:up`, `task test:build`,
`task test:install` — if you want to stop partway.

It uses the `generic` profile and its own `values.local.yaml`, so it is a safe
rehearsal of the install flow rather than of MetalLB and Longhorn specifically.

---

## Troubleshooting

### The LoadBalancer Service has no address, or has one that does not route

Usually k3s's built-in ServiceLB competing with MetalLB. Reinstall k3s with
`--disable servicelb`. Otherwise check the pool actually contains the address
the Service is asking for:

```bash
kubectl get ipaddresspool -n metallb-system -o yaml
kubectl get svc proxy-lb -n bmc -o yaml | grep -A2 annotations
```

### File sessions open but nothing connects

The SFTP NodePort range is not forwarded at your firewall, or the port collides
with something. The chart notes that the panel does no range check and no
collision detection against the NodePorts the platform chart hardcodes
(redis 30079, prometheus 30090 in `development` environment).

### RWX volumes fail only when a file session opens

A node is missing `nfs-common`. Longhorn's RWX is NFS-backed, and the failure
appears at mount time on whichever node the session lands on — so it can look
intermittent on a multi-node cluster.

### The certificate never issues

Port 80 is not reachable from the internet, or DNS does not resolve to your
MetalLB address yet. Check the challenge:

```bash
kubectl describe challenge -n bmc
```

`failed to perform self check` means cert-manager could not reach the token over
plain HTTP.

### Traefik lost its shared-IP annotation

A k3s upgrade re-applied its own manifest. Re-run `task install`, or:

```bash
kubectl annotate svc traefik -n kube-system metallb.io/allow-shared-ip=shared-ip-key --overwrite
```

---

## Teardown

```bash
task uninstall PROFILE=baremetal-metallb
```

Removes the BMC releases. `task teardown` is for cloud profiles — there is no
infrastructure layer to destroy here, and it will tell you so rather than doing
anything surprising.

Secrets are not deleted:

```bash
kubectl delete secret bmc-secrets -n bmc
```

Longhorn volumes outlive the release. Delete the PVCs in the `bmc` namespace if
you want the disk space back, and be sure first — that is your worlds.
