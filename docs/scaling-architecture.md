# Scaling architecture: migration plan

A plan to remove BMC's three structural scaling limits: the shared
ReadWriteMany volume, the single-instance Redis and databases, and the
single-threaded manager on the player path.

Three independent tracks. **Track A is the one that changes the architecture**;
B and C are smaller and can run in parallel or be deferred.

Every phase is independently shippable and independently valuable. None
requires the next one to land.

---

## Why

Three findings from reading the current code, each verifiable:

**The shared volume is already read-only for the deployments that scale.**
`scalable-deployment-chart/scripts/entrypoint.sh` touches the shared mount
exactly once, at line 12, to `cp -r` it into `/tmp/minecraft-server`, then runs
from local disk and never writes back. `proxy-chart` does the same. Only
`persistent-deployment-chart` runs in place (`cd "<mountPath>"`).

So BMC already has an immutable-template / mutable-state split. It is just
implemented with one shared filesystem doing both jobs — which means a
scale-up has N pods each copying a whole server directory from one NFS export
at the same time. The design is fastest when you do not need it and slowest
exactly when you do.

**RWX is needed for file sessions only because they are split across two pods.**
A session creates `file-session-chart/templates/pod.yaml` (which already runs
two containers, `file-editor` and `activity-watcher`) and a separate
`sftp-server.yaml` pod, both mounting the same PVC. Two pods can land on two
nodes, so the claim must be ReadWriteMany. There is no structural reason for
the split: SFTP is a third container's worth of work in its own pod. Merge it
in and exactly one pod holds the claim, which ReadWriteOnce satisfies with no
scheduling constraints at all.

**Persistent deployments are the one place multi-mount is real**, because the
server pod holds the volume while a session mounts it too. That is also the
place where RWX costs nothing: a persistent deployment is single-instance by
definition, so the volume sees two or three mounts, never N. The scaling
problem was never RWX itself — it was N instances reading one filesystem at
once.

**The manager is on the player path.** `QueueManager.queuePlayer` →
`findInstance` → `sendPlayerToInstance` runs in the single manager pod, and
`PlayerListenerTask` handles every connect and disconnect over Redis pub/sub
with a Redis write per event.

---

## Track A — Artifact-based deployment

Replace "every instance reads a shared filesystem" with "every instance pulls a
versioned artifact".

### Phase A0 — One pod per file session  ✅ done

The smallest useful change, and the one that proves the RWO assumption before
anything depends on it.

Move the SFTP container into the existing session pod, so a session is one pod
rather than two.

| Where | Change |
|---|---|
| `big-minecraft` `file-session-chart/templates/pod.yaml` | Add the `sftp` container (image, port 22, the `sftp.json` ConfigMap mount) |
| `big-minecraft` `file-session-chart/templates/sftp-server.yaml` | Delete the Pod; keep the Services, retarget their selector at the merged pod's label |
| `bmc-panel` `services/pulumi/pulumiDeploymentService.ts` → `createFileSessionProgram` (~line 392) | One pod name instead of two |

Deliberately **not** pod affinity. Affinity would work, but it means the panel
looking up the running server's node and then handling that node being full,
cordoned or draining, and the server being rescheduled mid-session — every one
of which surfaces to a user as "I cannot open a file session right now". One
pod has none of those states.

**Value on its own:** a session stops requiring ReadWriteMany. Nothing changes
on an RWX cluster. Test by pointing `storage.classes.shared.name` at an RWO
class on a scratch cluster and opening a session.

**Trade:** the SFTP container now shares the session's lifecycle and restarts
with it — arguably correct, since they are one session.

**Rollback:** split the pod back; the Services are unchanged.

### Phase A1 — Read-only template mounts  ✅ done

Makes the existing contract explicit and prevents accidental writes.

| Where | Change |
|---|---|
| `bmc-manager` `crd/GameServerSpec.java` → `VolumeSpec` | Add `readOnly` |
| `bmc-manager` `controller/PodBuilder.java` → `buildVolumeMounts` (~line 91) | Honour it on the mount |
| `big-minecraft` GameServer CRD | Add `volume.readOnly` to the schema |
| `big-minecraft` `scalable-deployment-chart`, `proxy-chart` templates | Set `readOnly: true` |

**Value on its own:** an accidental write from a plugin or an admin script can
no longer corrupt the template other instances are copying from.

**Risk:** low, but real. If a plugin writes to the mount today it now fails
loudly instead of silently diverging — which is the point, and worth a release
note for operators.

Implementing this found one such writer in BMC itself: the proxy entrypoint
downloaded `bmc-velocity.jar` into `<mountPath>/plugins` on the shared volume
*before* copying to local, so every proxy start wrote to shared storage and
several proxies starting at once all wrote the same file concurrently. It now
downloads into the pod-local copy instead. That change is worth having on its
own, independent of the read-only mount.

### Phase A2 — Artifact store and publish

| Where | Change |
|---|---|
| `big-minecraft` `helmfile.yaml`, `values.yaml` | Optional MinIO release, gated on `global.artifactStore.install`, mirroring `nfsServer` |
| `big-minecraft` `profiles/*.yaml` | Cloud profiles point at S3/GCS instead of installing MinIO |
| `bmc-panel` `features/deployments/controllers/deploymentManifestManager.ts` | Record `artifactVersion` in the manifest |
| `bmc-panel` new `services/artifactService.ts` | `publish(deployment)`: pack the deployment directory, upload as `deployments/<name>/<version>.tar.zst`, return version + checksum |
| `bmc-panel` `services/fileSessionService.ts` | Auto-publish when a session closes |

Bucket layout keeps versions immutable and rollback trivial:

```
deployments/<name>/v3.tar.zst      ← content-addressed or monotonic
deployments/<name>/latest          ← pointer, updated on publish
```

**Value on its own:** versioning and rollback exist before anything consumes
them. Publishing is observable and reversible while the old copy path still
runs.

**Auto-publish on session close is what keeps the UX unchanged.** Sessions
already have a lifecycle and a timeout, so "edit, close, restart" feels like
today's "edit, restart".

### Phase A3 — Instances pull artifacts

| Where | Change |
|---|---|
| `bmc-manager` `crd/GameServerSpec.java` | Add `artifact { url, version, checksum }` |
| `bmc-manager` `controller/PodBuilder.java` → `buildPod` (~line 16) | Add an init container that fetches and extracts into an `emptyDir` |
| `bmc-manager` `PodBuilder.buildVolumes` (~line 113) | `emptyDir` for the extracted template; drop the PVC for scalable/proxy |
| `big-minecraft` `scalable-deployment-chart`, `proxy-chart` `scripts/entrypoint.sh` | Delete the `cp -r` — the init container has already staged it |
| `big-minecraft` same charts | Stop declaring the shared PVC |

The init container replaces work the entrypoint does today, so wall-clock
startup for a single instance is comparable. The difference is that object
storage does not degrade with concurrency, so fifty simultaneous pulls cost
roughly what one does — where fifty simultaneous NFS reads share one export's
bandwidth.

**Value on its own:** the scaling ceiling moves. Game pods stop touching a
shared filesystem entirely.

**Risk:** the artifact store becomes a hard dependency of pod startup. Mitigate
with a checksum check, a retry/backoff in the init container, and an explicit
`Pending: no published version` state rather than a crash loop. This also fixes
today's "empty filesystem → `Jar file not found!` crash loop" bootstrap
problem, which is currently indistinguishable from a real failure.

**Rollback:** keep the `cp -r` path behind a flag for one release.

### Phase A4 — Make RWX conditional on persistent deployments

Not "remove RWX". Persistent deployments genuinely need it — the server pod
holds the volume while a session mounts it — and there it is cheap, because a
persistent deployment is one instance, so the volume never sees more than a
handful of mounts.

The contract splits in two: **ReadWriteOnce always, ReadWriteMany only if you
run persistent deployments.**

| Where | Change |
|---|---|
| `big-minecraft` `charts/bmc-chart/values.yaml` | Split the classes: `shared` becomes RWO; add a separate RWX class for persistent, plus a flag for whether persistent deployments are in use |
| `big-minecraft` `profiles/*.yaml` | Set both per profile |
| `big-minecraft` `persistent-deployment-chart` | Reference the RWX class |
| `big-minecraft` `scripts/preflight.sh` | Probe RWX only when persistent is enabled — same shape as the existing `nfsServer` guard |
| `big-minecraft` `scripts/validate-config.sh` | Make the RWX requirement conditional |
| `big-minecraft` `profiles/gke.yaml`, `terraform/eks` | NFS server and EFS become opt-in rather than required |
| docs | The capability contract in README and all three install guides |

Roughly 50–80 lines, all in `big-minecraft`. No panel or manager code.

**What this is worth, concretely** — for a network with no persistent
deployments:

- **EKS** — no EFS filesystem, no EFS CSI driver, no mount targets, no `efs-sc`
- **GKE** — no NFS server pod, no 100 GiB backing disk (~$10/month), one fewer
  single point of failure, and the Filestore-vs-NFS decision disappears
- **Bare metal** — no `nfs-common` on every node. That is the footgun that
  mounts RWO volumes happily and fails only when a file session opens, on
  whichever node it lands on

A pure minigame network needs no ReadWriteMany at all. A survival network keeps
exactly what it has today, and pays nothing extra for it.

### Phase A5 — Optional: cold-start optimisation

Only if measurement shows pull time dominates. Either a node-local artifact
cache (a DaemonSet, or `hostPath` keyed by checksum), or baking the *immutable
template* — jar, plugins, configs, no worlds — into a per-deployment image so
node image caching applies.

Images were considered as the primary approach and rejected for now: a registry
becomes a hard dependency (another HA stateful service on bare metal), a
builder is needed in-cluster, worlds are gigabytes of layer churn, and every
file edit becomes a build — turning a seconds-long "edit and restart" into a
minutes-long pipeline. The artifact model gets most of the benefit without any
of that.

---

## Track B — Redis and database HA

### B1 — `redis.external`, mirroring the databases

`charts/bmc-chart/templates/redis-server.yaml` has no `external` conditional,
unlike `mariadb-server.yaml` and `mongodb-server.yaml`, which are both wrapped
in `{{- if not .Values.global.<db>.external }}`. Add the same flag and guard.
~15 lines, and it unblocks everything else in this track.

### B2 — Sentinel, not Cluster

`bmc-manager` `controllers/RedisManager.java` line 31 constructs
`new JedisPool(poolConfig, redisHost, redisPort)` — a single-endpoint pool. Two
consequences:

- Sentinel needs `JedisSentinelPool`; Cluster needs `JedisCluster`.
- The manager enumerates instances with `SCAN`. In Redis **Cluster**, SCAN is
  per-node over sharded keys and would silently return partial results.

**Sentinel is the path**: one master, three sentinels, automatic failover,
identical semantics for both SCAN and pub/sub. Change the pool type in
`bmc-manager`, `bmc-panel`, and `bmc-velocity`, then deploy a Sentinel-mode
Redis chart. Cluster would be a rewrite of the key-scanning access pattern.

### B3 — Databases

Both already support `external: true`, so this is mostly infrastructure:
MariaDB Galera (3 nodes on RWO) and MongoDB as a replica set. The one code
concern is the Mongo connection URI — check whether the panel builds it from
`host`/`port` alone, which a replica set needs to be told about.

---

## Track C — Manager throughput

Ordered by payoff per line changed.

1. **Remove the debug logging from the routing path.** `QueueManager.findInstance`
   prints six-plus lines per routing decision, including one *inside* the
   per-instance loop. `System.out.println` is synchronized and lands in the
   container log. At thousands of joins per second across hundreds of
   instances, this is likely the dominant cost and the cheapest thing to fix.
2. **Index instances by game** instead of the O(n) scan in
   `findSpreadInstance` / `findFillInstance`.
3. **Batch or debounce `updateInstance`** in `PlayerListenerTask`, which
   currently writes to Redis on every connect and disconnect.
4. **Leader election**, then shard by game, so the manager can run more than
   one replica. It holds instance state in memory
   (`BMCManager.instanceManager`), so two replicas today would double-count
   players and double-scale deployments.

Items 1–3 are contained changes to existing methods. Item 4 is a design change
and should follow measurement, not precede it.

---

## Suggested order

**A0 → A1 → B1 → A2 → A3 → A4**, with **C1–C3** slotted in whenever convenient
— they are small and independent.

A0 and A1 are cheap and de-risk everything after them — A0 in particular is a
few dozen lines of YAML and proves the ReadWriteOnce assumption before anything
depends on it. B1 is 15 lines and unblocks a whole track. A2 is the largest
single piece of work but ships without changing runtime behaviour. A3 is where
the benefit lands, and A4 is where the contract simplifies.

**A4 depends on A3, not just A0.** It is tempting to think merging the session
pods is enough to drop to ReadWriteOnce, but it is not: every scalable instance
mounts the deployment's claim today in order to `cp -r` from it, so N instances
are N mounts regardless of how many pods a session uses. A0 removes one mount;
A3 removes the other N. Both are needed before the access mode can change.

How many pods hold a deployment's claim, by phase:

| | today | after A0 | after A0+A3 |
|---|---|---|---|
| scalable / proxy | N instances + 2 session | N instances + 1 session | **1 session** |
| persistent | 1 server + 2 session | 1 server + 1 session | 1 server + 1 session |

So after A3, a scalable deployment needs only ReadWriteOnce, and a persistent
one needs ReadWriteMany for its two mounts — which is exactly the conditional
contract A4 describes.

## What to measure

Before A3, capture on a real cluster so the change can be judged rather than
assumed:

- p50 and p99 instance start time, at 1 instance and at 20 scaling at once
- NFS/EFS read throughput during a scale-up
- Manager CPU and routing latency at a realistic join rate

The current proxy entrypoint already downloads `bmc-velocity.jar` from GitHub
on every start — 1554k, observed at 10.3 MB/s — so a network fetch on the boot
path is already accepted practice, and gives a baseline to compare against.
