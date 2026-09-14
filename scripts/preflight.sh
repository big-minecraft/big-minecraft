#!/bin/bash
set -euo pipefail

# Verify that the target cluster satisfies BMC's capability contract.
#
# This replaces the old detect-dependencies.sh, which sniffed for Traefik /
# MetalLB / cert-manager by name and wrote a values.auto.yaml that nothing ever
# read. Vendor names do not tell you whether a cluster can actually run BMC.
# These probes test behaviour instead, so they work identically on k3s, EKS,
# GKE, AKS or anything else.
#
# Every probe cleans up after itself.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROFILE="${PROFILE:-baremetal}"
CHART_DIR="${CHART_DIR:-charts/bmc-chart}"
# BMC_VALUES_FILE in the chain because helmfile.yaml.gotmpl honours it and
# scripts/local-test.sh sets it. Without it here, `BMC_VALUES_FILE=... task
# preflight` probed one file while the install read another.
VALUES_FILE="${VALUES_FILE:-${BMC_VALUES_FILE:-${CONFIG_DIR:-config}/${PROFILE:-baremetal}.yaml}}"
NS="${PREFLIGHT_NAMESPACE:-bmc-preflight}"
TIMEOUT="${PREFLIGHT_TIMEOUT:-90}"
# Storage gets longer: a network-attached volume must be provisioned, attached
# and mounted before a pod is ready, which exceeds 90s on a small cluster.
STORAGE_TIMEOUT="${PREFLIGHT_STORAGE_TIMEOUT:-180}"
# Port for the LoadBalancer probe. Must not collide with the real game edge
# (25565 java, 19132 bedrock) when they share one address.
PREFLIGHT_LB_PORT="${PREFLIGHT_LB_PORT:-34567}"

FAILED=0
WARNED=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; FAILED=1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARNED=1; }
skip() { echo -e "    ${YELLOW}-${NC} $1"; }

echo "=========================================="
echo "Preflight: cluster capability contract"
echo "  profile: $PROFILE"
echo "=========================================="
echo ""

# ---------------------------------------------------------------- values ----
read_value() {
  # $1 = yaml path. Merge the layers with yq rather than helm so this works
  # without a chart render.
  local files=("$CHART_DIR/values.yaml" "profiles/${PROFILE}.yaml")
  [ -f "$VALUES_FILE" ] && files+=("$VALUES_FILE")
  yq eval-all '. as $item ireduce ({}; . * $item)' "${files[@]}" 2>/dev/null | yq "$1" - 2>/dev/null
}

if [ ! -f "profiles/${PROFILE}.yaml" ]; then
  echo -e "${RED}Unknown profile '${PROFILE}'${NC}. Available:"
  ls profiles/ | sed 's/\.yaml$//' | sed 's/^/  - /'
  exit 1
fi

# Loudly, not silently. read_value drops this layer when the file is absent, so
# every value below falls back to the profile and chart defaults -- and
# preflight then reports those defaults as though they were the operator's
# configuration. The failures it prints are real, but the names in them were
# never chosen by anyone, which sends you looking for the mistake in a file
# that does not exist. validate-config.sh already hard-stops here; this makes
# the two agree.
if [ ! -f "$VALUES_FILE" ]; then
  echo -e "${RED}No configuration file: $VALUES_FILE${NC}"
  echo ""
  echo "  Everything below would be checked against the profile and chart"
  echo "  defaults, not your cluster's actual configuration."
  echo ""
  echo "  Run: task config:init PROFILE=${PROFILE}"
  echo ""
  echo "  To probe the defaults deliberately anyway:"
  echo "    PREFLIGHT_ALLOW_NO_CONFIG=true task preflight PROFILE=${PROFILE}"
  if [ "${PREFLIGHT_ALLOW_NO_CONFIG:-false}" != "true" ]; then
    exit 1
  fi
  echo ""
  echo -e "${YELLOW}Continuing against defaults -- results describe no real install.${NC}"
  echo ""
fi

SHARED_CLASS=$(read_value '.global.storage.classes.shared.name')
SHARED_MODE=$(read_value '.global.storage.classes.shared.accessMode')
PERSISTENT_CLASS=$(read_value '.global.storage.classes.persistent.name')
PERSISTENT_MODE=$(read_value '.global.storage.classes.persistent.accessMode')
USES_PERSISTENT=$(read_value '.global.storage.persistentDeployments')
DB_CLASS=$(read_value '.global.storage.classes.database.name')
DB_MODE=$(read_value '.global.storage.classes.database.accessMode')
INGRESS_CLASS=$(read_value '.global.ingress.className')
TLS_MODE=$(read_value '.global.ingress.tls.mode')
TLS_ISSUER=$(read_value '.global.ingress.tls.issuer')
ISSUER_NAME=$(read_value '.global.certManager.clusterIssuerName')
GAME_EDGE=$(read_value '.global.edge.game.type')
# Whether the install will bring its own ingress controller, in which case a
# missing IngressClass is expected rather than disqualifying.
INSTALL_NGINX=$(read_value '.global.ingressNginx.install')
# Whether BMC brings its own RWX storage provider on this profile.
INSTALL_NFS=$(read_value '.global.nfsServer.install')
REDIS_EXTERNAL=$(read_value '.global.redis.external')
REDIS_HOST=$(read_value '.global.redis.host')

# The namespace BMC itself is installed into, as opposed to $NS, which is the
# throwaway namespace these probes run in.
NS_TARGET=$(read_value '.global.namespace')
NS_TARGET="${NS_TARGET:-bmc}"

cleanup() { kubectl delete namespace "$NS" --wait=false &>/dev/null || true; }
trap cleanup EXIT

# A previous run's namespace may still be Terminating. `kubectl get` succeeds on
# a Terminating namespace, so a naive create-if-missing leaves every subsequent
# apply failing silently and reports the whole cluster as broken. Wait it out.
if kubectl get namespace "$NS" &>/dev/null; then
  echo "Waiting for a previous preflight namespace to finish terminating..."
  kubectl delete namespace "$NS" --wait=true --timeout=180s &>/dev/null || true
fi
kubectl create namespace "$NS" >/dev/null

# ------------------------------------------------------- server version ----
echo "Kubernetes version"
SERVER_MINOR=$(kubectl version -o json 2>/dev/null | yq -p json '.serverVersion.minor' - 2>/dev/null | tr -dc '0-9' || echo "0")
if [ -n "$SERVER_MINOR" ] && [ "$SERVER_MINOR" -ge 26 ] 2>/dev/null; then
  pass "server is 1.${SERVER_MINOR} (>= 1.26)"
else
  warn "server reports minor '${SERVER_MINOR}'; BMC needs >= 1.26 for a mixed TCP+UDP LoadBalancer (MixedProtocolLBService)"
fi
echo ""

# --------------------------------------------------------------- storage ----
probe_storage() {
  # $1 name  $2 class  $3 accessMode  $4 replicas
  #
  # The consumer Deployment is created UP FRONT, not after the claim binds.
  # A StorageClass with volumeBindingMode: WaitForFirstConsumer -- which is the
  # default for EBS gp3, GCE PD, Azure managed-csi and k3s local-path -- leaves
  # the PVC Pending until a pod actually schedules against it. Waiting for
  # "Bound" before creating a consumer therefore times out on almost every
  # cloud, reporting a working cluster as broken.
  #
  # Waiting on readyReplicas instead covers both binding modes at once, and for
  # replicas=2 it simultaneously proves concurrent multi-pod access.
  local name="$1" class="$2" mode="$3" replicas="$4"

  kubectl delete deploy "$name" -n "$NS" --wait=true &>/dev/null || true
  kubectl delete pvc "$name" -n "$NS" --wait=true &>/dev/null || true

  {
    echo "apiVersion: v1"
    echo "kind: PersistentVolumeClaim"
    echo "metadata: {name: $name, namespace: $NS}"
    echo "spec:"
    echo "  accessModes: [\"$mode\"]"
    [ -n "$class" ] && [ "$class" != "null" ] && echo "  storageClassName: $class"
    echo "  resources: {requests: {storage: 1Gi}}"
  } | kubectl apply -f - &>/dev/null || return 1

  cat <<EOF | kubectl apply -f - &>/dev/null || return 1
apiVersion: apps/v1
kind: Deployment
metadata: {name: $name, namespace: $NS}
spec:
  replicas: $replicas
  selector: {matchLabels: {app: $name}}
  template:
    metadata: {labels: {app: $name}}
    spec:
      containers:
        - name: c
          image: busybox:1.36
          command: ["sh", "-c", "sleep 600"]
          volumeMounts: [{name: v, mountPath: /data}]
      volumes:
        - name: v
          persistentVolumeClaim: {claimName: $name}
EOF

  for _ in $(seq 1 "$STORAGE_TIMEOUT"); do
    R=$(kubectl get deploy "$name" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "${R:-0}" -ge "$replicas" ] 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# "no claim bound" points at the storage class, which is usually fine. The real
# cause is normally the provisioner having no schedulable capacity, or a claim
# stuck behind a specific event -- both knowable, so say them.
diagnose_storage() {
  local name="$1"

  # Longhorn schedules on RESERVED space, so a disk goes unschedulable long
  # before it is full: every replica counts, used or not.
  if kubectl get nodes.longhorn.io -n longhorn-system &>/dev/null; then
    local unsched
    unsched=$(kubectl get nodes.longhorn.io -n longhorn-system -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for n in d.get("items", []):
    name = n.get("metadata", {}).get("name", "?")
    for _, disk in (n.get("status", {}).get("diskStatus") or {}).items():
        for c in (disk.get("conditions") or []):
            if c.get("type") == "Schedulable" and c.get("status") != "True":
                msg = str(c.get("message", ""))[:160]
                print(name + ": " + str(c.get("reason")) + " -- " + msg)
' 2>/dev/null || true)
    if [ -n "$unsched" ]; then
      skip "Longhorn has no schedulable capacity -- this is the real cause:"
      echo "$unsched" | sed 's/^/      /'
      skip "Longhorn reserves space per REPLICA, so unused volumes still count."
      skip "Run 'task validate PROFILE=$PROFILE' -- it lists volumes stranded by"
      skip "a datastore mode change, which is the usual reason for this."
      return
    fi
  fi

  # Otherwise surface the claim's own last event, which names the actual fault.
  local ev
  ev=$(kubectl get events -n "$NS" --field-selector "involvedObject.name=$name" \
        --sort-by=.lastTimestamp -o jsonpath='{.items[-1:].message}' 2>/dev/null || true)
  [ -n "$ev" ] && skip "last event on the claim: ${ev:0:180}"
}

cleanup_probe() {
  # Synchronous, so pods release the volume before the next probe starts.
  # Otherwise each probe races the previous one's detach and a healthy class
  # times out. The claim goes in the background -- only the release matters.
  kubectl delete deploy "$1" -n "$NS" --wait=true --timeout=60s &>/dev/null || true
  kubectl delete pvc "$1" -n "$NS" --wait=false &>/dev/null || true
}

echo "Storage: shared (staging, and instances that do not pull artifacts)"
if [ -z "$SHARED_CLASS" ] || [ "$SHARED_CLASS" = "null" ] || [ "$SHARED_CLASS" = '""' ]; then
  warn "global.storage.classes.shared.name is unset -- the cluster default StorageClass will be used"
  skip "on most clouds the default is RWO-only and will fail the next check"
fi
# Replica count follows the declared access mode: probing ReadWriteOnce with two
# pods would fail on a perfectly good class.
SHARED_REPLICAS=1
[ "$SHARED_MODE" = "ReadWriteMany" ] && SHARED_REPLICAS=2

# `task install` runs `task storage` first so this probe tests a real class. Run
# on its own against a fresh cluster it will not exist yet, and probing it would
# just wait for a PVC that can never bind.
if [ "$INSTALL_NFS" = "true" ] && ! kubectl get storageclass "$SHARED_CLASS" &>/dev/null; then
  warn "StorageClass '$SHARED_CLASS' not found yet (BMC installs its own NFS server)"
  skip "run 'task storage PROFILE=$PROFILE' first to test ReadWriteMany for real"
  skip "'task install' does this automatically, before preflight"
elif probe_storage preflight-shared "$SHARED_CLASS" "$SHARED_MODE" "$SHARED_REPLICAS"; then
  SHARED_PROVED="${SHARED_CLASS}/${SHARED_MODE}/${SHARED_REPLICAS}"
  if [ "$SHARED_REPLICAS" = "2" ]; then
    pass "two pods mount a '${SHARED_CLASS:-<default>}' ${SHARED_MODE} claim simultaneously"
  else
    pass "a '${SHARED_CLASS:-<default>}' claim binds and mounts with ${SHARED_MODE}"
  fi
else
  fail "no claim bound for '${SHARED_CLASS:-<default>}' with ${SHARED_MODE}"
  [ "$SHARED_REPLICAS" = "2" ] && skip "this class must allow several pods to mount one claim at once"
  diagnose_storage preflight-shared
  SHARED_PROVED=""
fi
cleanup_probe preflight-shared
echo ""

# ReadWriteMany, and only when something actually needs it.
#
# Persistent deployments run in place on their volume while a file session can
# mount it too. Every other type pulls artifacts into a pod-local emptyDir, so an
# installation with no persistent deployments needs no RWX class at all -- no
# EFS, no NFS server, no nfs-common on every node.
echo "Storage: persistent deployments (ReadWriteMany)"
if [ "$USES_PERSISTENT" != "true" ]; then
  pass "not in use (storage.persistentDeployments is false) -- no RWX class needed"
  skip "turn it on before creating a persistent deployment, or its PVC will never bind"
elif [ -n "${SHARED_PROVED:-}" ] && [ "$SHARED_PROVED" = "${PERSISTENT_CLASS}/${PERSISTENT_MODE}/2" ]; then
  # Profiles often point shared and persistent at one class -- bare metal uses
  # longhorn for both. Re-probing an identical class/mode/replica triple proves
  # nothing the check above has not, and it is not free: each ReadWriteMany
  # volume brings up its own Longhorn share-manager pod, so the second probe
  # races the first one's teardown and can time out on a cluster that is
  # perfectly healthy.
  pass "'${PERSISTENT_CLASS}' ${PERSISTENT_MODE} already proven by the shared-storage probe"
elif probe_storage preflight-persistent "$PERSISTENT_CLASS" "$PERSISTENT_MODE" 2; then
  pass "two pods mount a '${PERSISTENT_CLASS:-<default>}' ${PERSISTENT_MODE} claim simultaneously"
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${NODE_COUNT:-1}" -le 1 ] 2>/dev/null; then
    warn "single-node cluster: this proves co-located access, not cross-node RWX"
    skip "a node-local class can pass here and still fail on a real multi-node cluster"
  fi
else
  fail "two pods could NOT share a '${PERSISTENT_CLASS:-<default>}' claim with ${PERSISTENT_MODE}"
  diagnose_storage preflight-persistent
  skip "persistent deployments need RWX (Longhorn/NFS, EFS, Filestore, Azure Files)"
  skip "or set storage.persistentDeployments to false if you do not use them"
fi
cleanup_probe preflight-persistent
echo ""

echo "Storage: database (MariaDB + MongoDB)"
MARIA_EXTERNAL=$(read_value '.global.mariaDB.external')
MONGO_EXTERNAL=$(read_value '.global.mongoDB.external')
if [ "$MARIA_EXTERNAL" = "true" ] && [ "$MONGO_EXTERNAL" = "true" ]; then
  pass "both databases are external -- no in-cluster database storage needed"
elif probe_storage preflight-db "$DB_CLASS" "$DB_MODE" 1; then
  pass "a '${DB_CLASS:-<default>}' claim binds and mounts with ${DB_MODE}"
  cleanup_probe preflight-db
else
  fail "no claim bound for database storage class '${DB_CLASS:-<default>}' with ${DB_MODE}"
  diagnose_storage preflight-db
  cleanup_probe preflight-db
fi
echo ""

# --------------------------------------------------------------- ingress ----
echo "Ingress"
if [ -z "$INGRESS_CLASS" ] || [ "$INGRESS_CLASS" = "null" ] || [ "$INGRESS_CLASS" = '""' ]; then
  AVAILABLE=$(kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  if [ -n "$AVAILABLE" ]; then
    fail "global.ingress.className is unset; cluster offers: $AVAILABLE"
  else
    fail "global.ingress.className is unset and the cluster has no IngressClass"
  fi
elif kubectl get ingressclass "$INGRESS_CLASS" &>/dev/null; then
  pass "IngressClass '$INGRESS_CLASS' exists"
elif [ "$INSTALL_NGINX" = "true" ]; then
  # Same reasoning as the cert-manager check below: this profile installs its
  # own ingress controller during `task deploy`, which runs AFTER preflight.
  # Failing here would make a fresh cluster impossible to install onto -- the
  # gate would demand something the very next step creates.
  warn "IngressClass '$INGRESS_CLASS' not found yet (the install will add it)"
  skip "global.ingressNginx.install is true, so helmfile installs ingress-nginx"
else
  AVAILABLE=$(kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  fail "IngressClass '$INGRESS_CLASS' not found; cluster offers: ${AVAILABLE:-<none>}"
fi
echo ""

# ------------------------------------------------------------------- TLS ----
echo "TLS (mode: ${TLS_MODE})"
case "$TLS_MODE" in
  cluster-issuer)
    # Written as an if: the `A || B && C` form returns non-zero when every
    # test fails, which would trip `set -e`.
    WANT="${TLS_ISSUER}"
    if [ -z "$WANT" ] || [ "$WANT" = "null" ] || [ "$WANT" = '""' ]; then
      WANT="$ISSUER_NAME"
    fi
    if ! kubectl get crd clusterissuers.cert-manager.io &>/dev/null; then
      warn "cert-manager CRDs are not installed yet (the install will add them)"
    elif kubectl get clusterissuer "$WANT" &>/dev/null; then
      pass "ClusterIssuer '$WANT' exists"
    else
      warn "ClusterIssuer '$WANT' not found -- set certManager.installClusterIssuer=true to have BMC create it"
    fi
    ;;
  existing-secret) pass "using a pre-existing TLS secret" ;;
  none)            warn "TLS is disabled -- the panel will be served over plain HTTP" ;;
  *)               fail "unknown ingress.tls.mode '$TLS_MODE' (expected cluster-issuer|existing-secret|none)" ;;
esac
echo ""

# ------------------------------------------------------------ LoadBalancer --
echo "Game edge (type: ${GAME_EDGE})"
if [ "$GAME_EDGE" != "LoadBalancer" ]; then
  skip "edge.game.type is '$GAME_EDGE', skipping LoadBalancer probe"
else
  # The probe carries the SAME annotations as the real game edge, and uses a
  # port the real edge does not. On a single-address MetalLB pool an
  # unannotated probe cannot be allocated at all (the address is already held
  # by proxy-lb), so a bare `create service loadbalancer` would report a
  # perfectly working cluster as broken. Reusing the annotations also means
  # this probe actually tests the configured edge settings.
  LB_ANNOTATIONS=$(read_value '.global.edge.game.annotations')
  {
    echo "apiVersion: v1"
    echo "kind: Service"
    echo "metadata:"
    echo "  name: preflight-lb"
    echo "  namespace: $NS"
    if [ -n "$LB_ANNOTATIONS" ] && [ "$LB_ANNOTATIONS" != "null" ] && [ "$LB_ANNOTATIONS" != "{}" ]; then
      echo "  annotations:"
      # Strip comments yq carries over from the values files.
      echo "$LB_ANNOTATIONS" | grep -v '^[[:space:]]*#' | sed 's/^/    /'
    fi
    echo "spec:"
    echo "  type: LoadBalancer"
    echo "  selector:"
    echo "    app: preflight-lb-no-backends"
    echo "  ports:"
    echo "    - protocol: TCP"
    echo "      port: ${PREFLIGHT_LB_PORT}"
    echo "      targetPort: ${PREFLIGHT_LB_PORT}"
  } | kubectl apply -f - &>/dev/null || true
  GOT=""
  for _ in $(seq 1 "$TIMEOUT"); do
    GOT=$(kubectl get svc preflight-lb -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [ -n "$GOT" ] && break
    sleep 1
  done
  if [ -n "$GOT" ]; then
    pass "a LoadBalancer Service was assigned '$GOT'"
  else
    fail "no LoadBalancer address after ${TIMEOUT}s -- is MetalLB (or a cloud LB controller) running?"
  fi
  kubectl delete svc preflight-lb -n "$NS" --wait=false &>/dev/null || true
fi
echo ""


# ---------------------------------------------------------------- egress ----
echo "Outbound egress from a pod"
kubectl -n "$NS" run preflight-egress --image=busybox:1.36 --restart=Never --command -- \
  sh -c 'wget -q --spider --timeout=15 https://github.com && echo OK' &>/dev/null || true
EGRESS=""
for _ in $(seq 1 "$TIMEOUT"); do
  P=$(kubectl get pod preflight-egress -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$P" = "Succeeded" ] && { EGRESS=ok; break; }
  [ "$P" = "Failed" ] && break
  sleep 1
done
if [ "$EGRESS" = "ok" ]; then
  pass "pods can reach the public internet"
else
  fail "pods cannot reach github.com"
  skip "the proxy entrypoint downloads bmc-velocity.jar from GitHub on every start"
fi
kubectl delete pod preflight-egress -n "$NS" --wait=false &>/dev/null || true
echo ""

# ---------------------------------------------------------------- result ----
echo "=========================================="
if [ "$FAILED" = "1" ]; then
  echo -e "${RED}Preflight FAILED${NC}"
  echo "=========================================="
  echo ""
  echo "This cluster does not satisfy the contract. Fix the items marked ✗,"
  echo "or pick a different profile (see profiles/)."
  exit 1
elif [ "$WARNED" = "1" ]; then
  echo -e "${YELLOW}Preflight passed with warnings${NC}"
else
  echo -e "${GREEN}Preflight PASSED${NC}"
fi
echo "=========================================="
echo ""
