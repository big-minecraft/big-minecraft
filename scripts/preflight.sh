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

PROFILE="${PROFILE:-baremetal-metallb}"
CHART_DIR="${CHART_DIR:-charts/bmc-chart}"
VALUES_FILE="${VALUES_FILE:-$CHART_DIR/values.custom.yaml}"
NS="${PREFLIGHT_NAMESPACE:-bmc-preflight}"
TIMEOUT="${PREFLIGHT_TIMEOUT:-90}"
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

SHARED_CLASS=$(read_value '.global.storage.classes.shared.name')
SHARED_MODE=$(read_value '.global.storage.classes.shared.accessMode')
DB_CLASS=$(read_value '.global.storage.classes.database.name')
DB_MODE=$(read_value '.global.storage.classes.database.accessMode')
INGRESS_CLASS=$(read_value '.global.ingress.className')
TLS_MODE=$(read_value '.global.ingress.tls.mode')
TLS_ISSUER=$(read_value '.global.ingress.tls.issuer')
ISSUER_NAME=$(read_value '.global.certManager.clusterIssuerName')
GAME_EDGE=$(read_value '.global.edge.game.type')

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

  for _ in $(seq 1 "$TIMEOUT"); do
    R=$(kubectl get deploy "$name" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "${R:-0}" -ge "$replicas" ] 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

cleanup_probe() {
  kubectl delete deploy "$1" -n "$NS" --wait=false &>/dev/null || true
  kubectl delete pvc "$1" -n "$NS" --wait=false &>/dev/null || true
}

echo "Storage: shared (game data + panel manifests)"
if [ -z "$SHARED_CLASS" ] || [ "$SHARED_CLASS" = "null" ] || [ "$SHARED_CLASS" = '""' ]; then
  warn "global.storage.classes.shared.name is unset -- the cluster default StorageClass will be used"
  skip "on most clouds the default is RWO-only and will fail the next check"
fi
# Two replicas: BMC mounts a deployment's volume into the game pod, an SFTP pod
# and a file-edit pod at once, so binding alone is not enough.
if probe_storage preflight-shared "$SHARED_CLASS" "$SHARED_MODE" 2; then
  pass "two pods mount a '${SHARED_CLASS:-<default>}' ${SHARED_MODE} claim simultaneously"
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${NODE_COUNT:-1}" -le 1 ] 2>/dev/null; then
    warn "single-node cluster: this proves co-located access, not cross-node RWX"
    skip "a node-local class can pass here and still fail on a real multi-node cluster"
  fi
else
  fail "two pods could NOT share a '${SHARED_CLASS:-<default>}' claim with ${SHARED_MODE}"
  skip "BMC needs a ReadWriteMany class (Longhorn/NFS, EFS, Filestore, Azure Files)"
  skip "file sessions mount a deployment's volume alongside the running server"
fi
cleanup_probe preflight-shared
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
