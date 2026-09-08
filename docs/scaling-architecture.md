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

### Phase A2 — Artifact store and publish  ✅ done

| Where | Change |
|---|---|
| `big-minecraft` `helmfile.yaml.gotmpl`, `values.yaml` | Optional MinIO release, gated on `global.artifactStore.install`, mirroring `nfsServer` |
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

**Done so far:** the store (`global.artifactStore`, an optional MinIO release
gated like the NFS server, installed by `task storage`), the credentials in
`bmc-secrets`, and `artifact-publish-chart` — a Job that mounts a deployment's
PVC read-only, packs it, and uploads the versioned object then the `latest`
pointer.

Publishing runs as a Job rather than streaming a tarball through the panel: a
server directory is routinely hundreds of megabytes, and the panel has no reason
to be in that path. It is also the only way to publish without an open file
session, because `PVCFileOperationsService` reaches deployment files only by
exec-ing into a session pod.

**Panel side:** `artifactService.ts` allocates the next version (`v1`, `v2`, …
monotonic, so "roll back one" means something obvious),
`PulumiDeploymentService.publishArtifact` applies the chart, and
`DeploymentManifestManager.setArtifactVersion` records the result in the
deployment's own YAML alongside `sftpPort`. The version is written only after
the Job applies, so a failed publish leaves the deployment pointing at the last
version that actually exists.

`terminateSession` publishes before tearing the session down, while the files
are final. A failed publish is logged and does not block termination — the
session pod holds the deployment's volume, so a stuck session is worse than a
missed publish.

The store stays `enabled: false` until A3 makes it load-bearing, so nothing
provisions storage it does not use yet, and `publish()` returns undefined
rather than failing when it is off.

**Auto-publish on session close is what keeps the UX unchanged.** Sessions
already have a lifecycle and a timeout, so "edit, close, restart" feels like
today's "edit, restart".

### Phase A3 — Instances pull artifacts  ✅ done

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

**Rollback:** the `cp -r` path is still there. Artifact mode engages only when
`artifactStore.enabled` is true *and* the deployment has an `artifactVersion`,
so anything not yet published behaves exactly as before.

Implementation note: the publish Job and the fetch init container both use
`mc mirror` rather than a tarball, because the `mc` image ships coreutils and mc
but **no tar** — verified by running it. Mirroring also keeps the version prefix
browsable in the bucket.

`readOnly` from A1 is ignored in artifact mode: the init container has to write
into the emptyDir, and nothing else shares it.

### Phase A4 — Make RWX conditional on persistent deployments  ✅ done

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

Landed as `storage.classes.persistent` (RWX, persistent and process deployments)
alongside `storage.classes.shared` (now RWO, staging and every type that pulls
artifacts), gated by `storage.persistentDeployments`. Preflight probes with two
pods only where two pods actually mount, and `validate-config` requires RWX only
when the flag is on.

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

### B1 — `redis.external`, mirroring the databases  ✅ done

`charts/bmc-chart/templates/redis-server.yaml` had no `external` conditional,
unlike `mariadb-server.yaml` and `mongodb-server.yaml`, which are both wrapped
in `{{- if not .Values.global.<db>.external }}`. It now has the same flag and
guard.

It turned out to need more than the guard. The runtime charts read
`.Values.server.redis.host`, which the deployment manifests in
`files/default-values/` hardcode to `redis-service` — so the panel and manager
would have moved to an external Redis while every game server kept dialling the
in-cluster Service that no longer exists. The templates now prefer the
panel-injected `global.redis.host` and fall back to the per-deployment value,
and each runtime chart declares `global.redis` so it renders standalone.

`validate-config.sh` also fails when `external` is true and the host is still
`redis-service`, because that combination produces no error anywhere — the
Deployment simply is not created, and the symptom is scaling quietly not
happening.

**Still missing for a managed Redis:** the clients connect with no
authentication or TLS. That is B2's territory.

### B1.5 — Managed HA on the cloud profiles  ❌ superseded

Built, then removed. ElastiCache/Memorystore for Redis and RDS/DocumentDB/Cloud
SQL for the databases all worked, but they meant two code paths, a per-cloud
story that did not exist on bare metal, DocumentDB being Mongo-*compatible*
rather than MongoDB, and no managed MongoDB on GCP at all.

Replaced by B4, which is one story everywhere.

### B2 — Sentinel-aware clients  ❌ likely unnecessary

The reason to need this was self-hosted Redis failover. The OT operator tracks
the current master via Sentinel and keeps a Service pointing at it, so a plain
single-endpoint `JedisPool` follows failover without knowing Sentinel exists --
the same trick the managed endpoints used.

Confirmed structurally: `bmc-redis-master` exists and the alias resolves to it.
Not yet confirmed behaviourally: nothing has killed the master and watched the
Service move. Until that test runs, treat this as likely-retired rather than
retired.

### B3 — Databases  ❌ superseded by B4

### B4 — Self-hosted HA for all three datastores  ✅ done

One `mode: single | ha` per datastore, identical on every profile.

| | Operator | Cluster resource | Alias |
|---|---|---|---|
| Redis | ot-container-kit redis-operator | RedisReplication + RedisSentinel | `redis-service` → `bmc-redis-master` |
| MariaDB | mariadb-operator | MariaDB (Galera) + Database | `mariadb-service` → `bmc-mariadb-primary` |
| MongoDB | MongoDB Community Operator | MongoDBCommunity ReplicaSet | `mongodb-service` → `bmc-mongodb-svc` |

Anti-affinity is `preferred`, not `required`: `ha` schedules on a single node
and protects against pod failure there, and spreads for node-level protection
as soon as there is somewhere to spread to. `required` would leave pods Pending
forever on a one-node cluster.

Four things only a live cluster found:

- Operators must be **Ready**, not merely installed, before their custom
  resources are applied. helmfile's `needs` orders releases but helm returns as
  soon as objects exist, so the MariaDB webhook had no endpoints and the
  resource was rejected. Fixed with `wait: true`.
- `RedisReplication` requires `spec.redisExporter.image` whenever the
  `redisExporter` block is present at all, so the block is omitted rather than
  disabled.
- The operator enables **TLS on Galera's replication channel by default**, and
  the members fail the handshake against each other -- no primary view forms
  and MariaDB refuses every connection. Disabled deliberately: pod-to-pod
  traffic in one namespace, matching the posture of the other two datastores.
- The operator creates **no database implicitly**. In `single` mode the
  container creates one from `MARIADB_DATABASE`; in `ha` mode a `Database`
  resource is required, or the panel connects to a schema that does not exist
  and its pool times out.

MongoDB additionally needed the panel change: `mongodbService.ts` built a
single-host URI, which cannot express a replica set. It now uses
`mongoDB.uri` verbatim when set, and `panel.yaml` assembles it -- the only place
that has the password.

**Still unproven:** Redis failover, and the replica-set URI in a panel image
that actually contains the change (the local test runs the published image).

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

Done so far: **A0, A1, B1, B1.5**. Next is **A2**.

B2 dropped in priority once B1.5 landed: cloud installs get HA Redis from the
provider, so Sentinel-aware clients are now only needed for self-hosted HA,
which in practice means bare metal.

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
