# Installing BMC on bare metal

For k3s (or any self-managed Kubernetes) with MetalLB and Longhorn. This is the
environment BMC was originally built for, and the one where you own every layer
— which means a few things the cloud guides get for free have to be set up by
hand.

There is no Terraform layer here. Nothing in this repo provisions your machines;
`profiles/baremetal.yaml` describes what the cluster must already
provide, and `task preflight` checks it.

```
your cluster        you build this -- k3s, MetalLB, Longhorn
    │
    │   profiles/baremetal.yaml  ← what BMC expects of it
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

`task preflight PROFILE=baremetal` tests all of it behaviourally.

---

## ReadWriteMany is conditional

Every deployment type except persistent pulls its files from the artifact store
into a pod-local emptyDir, so only one pod ever holds a deployment's volume: the
file session. That needs ReadWriteOnce.

**`nfs-common` is only needed for persistent deployments.** Longhorn's RWX is NFS-backed, and that is the only thing requiring it. An installation with no persistent deployments can set `storage.persistentDeployments` false and skip it on every node.

---

## Prerequisites

On your workstation: `kubectl`, `helm`, `helmfile`, `yq` (mikefarah's), `task`
and **`ansible`** — see the [README](../README.md#prerequisites-local) for
install commands. No cloud CLI and no OpenTofu are needed for this profile;
Ansible is what builds the cluster here, in place of Terraform.

```bash
brew install ansible          # macOS
sudo apt install -y ansible   # Debian/Ubuntu
```

Only `ansible-core` modules are used, so nothing has to be installed from
Galaxy.

On the machines: a Linux distribution with `systemd` and either `apt` or `dnf`,
reachable over SSH with a key, and an account that can `sudo`.

```bash
task verify PROFILE=baremetal
```

---

## 1. The cluster

Ansible builds it: k3s on every machine, Longhorn's node prerequisites, and
Longhorn itself. Physical machines and VMs are the same to it — it needs SSH
and sudo, nothing else.

```bash
# Creates config/infrastructure/baremetal.inventory.yml and stops so you can edit it.
task cluster PROFILE=baremetal

$EDITOR config/infrastructure/baremetal.inventory.yml

# Run it again to build.
task cluster PROFILE=baremetal
```

The inventory has two groups:

- **`k3s_servers`** — control-plane nodes. One is fine. Three gives a highly
  available control plane with embedded etcd, and the count must be **odd** or
  etcd cannot hold quorum. The playbook refuses an even number rather than
  building something that loses quorum the first time a node dies.
- **`k3s_agents`** — workers.

BMC wants **three nodes in total** so the HA datastore modes place their quorum
members in separate failure domains. Servers count toward that, so three
servers and no agents is a valid three-node cluster. Fewer works; it just is
not highly available, and the playbook says so as it runs.

### What it does, and why

- **k3s with `--disable servicelb`.** k3s ships Klipper, which also serves
  Services of type LoadBalancer and competes with MetalLB. The symptom is a
  Service that gets an address which does not route. Traefik stays enabled —
  `profiles/baremetal.yaml` expects `ingress.className: traefik`.
- **`open-iscsi` and `nfs-common` on every node**, before k3s. Longhorn backs
  ReadWriteMany with an internal NFS share, so a node missing `nfs-common`
  mounts ReadWriteOnce volumes perfectly well and fails only when a file
  session opens a RWX volume — long after install, looking like a BMC bug.
- **Longhorn**, sized to the cluster. Its replica count is clamped to the node
  count: left at 3 on a one-node cluster, every volume sits permanently
  Degraded.
- **A kubeconfig**, merged into `~/.kube/config` as the context
  `bmc-baremetal` — the same thing the cloud CLIs do. Your existing config is
  backed up first, and your current context is **not** switched:

```bash
kubectl config use-context bmc-baremetal
kubectl get nodes
```

Re-running is safe. Nodes that already have k3s are left alone, so the playbook
is also how you add a machine later.

---

## 2. MetalLB

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

## 3. DNS and ports

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

## 4. Configure

```bash
task config:init PROFILE=baremetal
$EDITOR config/baremetal.yaml
task validate PROFILE=baremetal
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

## 5. Install

```bash
task secrets:generate      # SAVE THE OUTPUT -- especially the invite code
task install PROFILE=baremetal
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

## 6. Verify

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

## Datastore mode is a one-way choice

`global.redis.mode`, `global.mariaDB.mode` and `global.mongoDB.mode` each take
`single` (one pod) or `ha` (an operator-managed cluster). **Pick before you have
data you care about.**

Switching is not a migration. The two modes use different storage:

| | single | ha |
|---|---|---|
| Runs as | a Deployment | an operator StatefulSet |
| Volume | `mariadb-pvc`, `mongodb-pvc` | `storage-bmc-mariadb-N`, `data-volume-bmc-mongodb-N`, … |

The Service name — `mariadb-service`, `mongodb-service` — is identical in both,
so nothing errors when you switch. The panel reconnects to what is now an
**empty** database, recreates its schema, and carries on. The old volumes are
not deleted (Kubernetes never deletes a StatefulSet's claims, so a database
survives a scale-to-zero) and not used either.

Two consequences:

- **The old data is stranded, not destroyed.** To get it back, switch the mode
  back. To move it, dump from one and restore into the other by hand.
- **Both sets keep reserving disk.** With Longhorn replicating each volume, a
  stranded HA set can quietly consume tens of gigabytes and push the node into
  `DiskPressure` — at which point *new* volumes stop being schedulable and the
  failure appears somewhere unrelated, like preflight's storage probes.

`task validate PROFILE=baremetal` reports stranded volumes and what to do with
them.

Given `ha` wants three nodes to mean anything — its anti-affinity is a
preference, so on fewer nodes the quorum members simply share a failure domain
— `single` is the right choice on a one- or two-node cluster.

---

## Trying it locally first

`task test:all` stands up a disposable k3d cluster with RWX storage, builds the
panel and manager images for your architecture, and installs BMC — without
touching your kubeconfig or `config/baremetal.yaml`:

```bash
task test:all       # create cluster, build images, install, report
task test:panel     # port-forward the panel to http://localhost:8080
task test:status    # what is running
task test:down      # delete everything
```

The steps are also available individually — `task test:up`, `task test:build`,
`task test:install` — if you want to stop partway.

It uses the `baremetal` profile and its own `values.local.yaml`, so it is a safe
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

Two levels, depending on how much you want gone.

**Remove BMC, keep the cluster:**

```bash
task uninstall PROFILE=baremetal
```

Removes the BMC releases and leaves k3s, Longhorn and your volumes in place.
Secrets are not deleted:

```bash
kubectl delete secret bmc-secrets -n bmc
```

Longhorn volumes outlive the release, so the worlds survive a reinstall. Delete
the PVCs in the `bmc` namespace if you want the disk space back, and be sure
first — that is your worlds.

**Remove everything, including k3s:**

```bash
task teardown PROFILE=baremetal
```

This prompts, then removes BMC and runs `ansible/uninstall.yml` against your
inventory. On each machine it runs k3s's own uninstall script, then clears
`/var/lib/longhorn` — which those scripts know nothing about, so left alone it
occupies disk that nothing references and feeds stale volume metadata to a
rebuilt cluster. Finally it drops the `bmc-baremetal` context from your
kubeconfig, so kubectl stops offering a cluster that cannot answer.

Workers are uninstalled before the control plane: pulling the API server out
from under a running agent just leaves it retrying against something that is
gone.

The machines themselves are untouched — only k3s and its data are removed, so
they are ready to be rebuilt with `task cluster PROFILE=baremetal`.

**Irreversible.** Every Longhorn volume, world and database on those machines
is destroyed.
