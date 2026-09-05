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
NS="${PREFLIGHT_NAMESPACE:-bmc-preflight}"
TIMEOUT="${PREFLIGHT_TIMEOUT:-90}"

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
  [ -f "$CHART_DIR/values.custom.yaml" ] && files+=("$CHART_DIR/values.custom.yaml")
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

kubectl get namespace "$NS" &>/dev/null || kubectl create namespace "$NS" >/dev/null

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
probe_pvc() {
  # $1 name  $2 class  $3 accessMode
  local name="$1" class="$2" mode="$3"
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

  for _ in $(seq 1 "$TIMEOUT"); do
    phase=$(kubectl get pvc "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = "Bound" ] && return 0
    sleep 1
  done
  return 1
}

echo "Storage: shared (game data + panel manifests)"
if [ -z "$SHARED_CLASS" ] || [ "$SHARED_CLASS" = "null" ] || [ "$SHARED_CLASS" = '""' ]; then
  warn "global.storage.classes.shared.name is unset -- the cluster default StorageClass will be used"
  skip "on most clouds the default is RWO-only and will fail the next check"
fi
if probe_pvc preflight-shared "$SHARED_CLASS" "$SHARED_MODE"; then
  pass "a '${SHARED_CLASS:-<default>}' claim binds with ${SHARED_MODE}"

  # Binding is not enough: BMC mounts a deployment's volume into the game pod,
  # an SFTP pod and a file-edit pod at the same time. Prove two pods can hold
  # the claim concurrently.
  cat <<EOF | kubectl apply -f - &>/dev/null || true
apiVersion: apps/v1
kind: Deployment
metadata: {name: preflight-rwx, namespace: $NS}
spec:
  replicas: 2
  selector: {matchLabels: {app: preflight-rwx}}
  template:
    metadata: {labels: {app: preflight-rwx}}
    spec:
      containers:
        - name: c
          image: busybox:1.36
          command: ["sh", "-c", "sleep 300"]
          volumeMounts: [{name: v, mountPath: /data}]
      volumes:
        - name: v
          persistentVolumeClaim: {claimName: preflight-shared}
EOF
  READY=0
  for _ in $(seq 1 "$TIMEOUT"); do
    R=$(kubectl get deploy preflight-rwx -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "${R:-0}" -ge 2 ] 2>/dev/null; then READY=1; break; fi
    sleep 1
  done
  if [ "$READY" = "1" ]; then
    pass "two pods mount that claim simultaneously"
  else
    fail "two pods could NOT mount the claim at once -- file sessions will hang"
    skip "this is the check a plain 'does the PVC bind' test would have passed"
  fi
  kubectl delete deploy preflight-rwx -n "$NS" --wait=false &>/dev/null || true
else
  fail "no claim bound for shared storage class '${SHARED_CLASS:-<default>}' with ${SHARED_MODE}"
  skip "BMC needs a ReadWriteMany class (Longhorn/NFS, EFS, Filestore, Azure Files)"
fi
echo ""

echo "Storage: database (MariaDB + MongoDB)"
MARIA_EXTERNAL=$(read_value '.global.mariaDB.external')
MONGO_EXTERNAL=$(read_value '.global.mongoDB.external')
if [ "$MARIA_EXTERNAL" = "true" ] && [ "$MONGO_EXTERNAL" = "true" ]; then
  pass "both databases are external -- no in-cluster database storage needed"
elif probe_pvc preflight-db "$DB_CLASS" "$DB_MODE"; then
  pass "a '${DB_CLASS:-<default>}' claim binds with ${DB_MODE}"
else
  fail "no claim bound for database storage class '${DB_CLASS:-<default>}' with ${DB_MODE}"
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
  kubectl -n "$NS" create service loadbalancer preflight-lb --tcp=25565:25565 &>/dev/null || true
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
