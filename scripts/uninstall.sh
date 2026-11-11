#!/bin/bash
set -euo pipefail

# Remove a BMC installation, leaving nothing behind.
#
# Ordering is the point. Runtime objects the panel created go first -- Helm
# never owned them, and their pods hold the PVCs open via pvc-protection.
# Datastore CRs go next, while their operators are still running, so finalizers
# get reconciled instead of stranding the namespace in Terminating forever.
#
# Nothing here patches a finalizer away. That deletes the object and orphans
# whatever it was protecting, which is a worse state than a visible hang.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="${NAMESPACE:-bmc}"
OP_NAMESPACE="${OP_NAMESPACE:-${NAMESPACE}-operators}"
PROFILE="${PROFILE:-baremetal}"
TIMEOUT="${UNINSTALL_TIMEOUT:-180}"
LABEL="app.kubernetes.io/part-of=bmc"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

# The CRs the panel and the chart create. Resolved through api-resources so a
# group whose CRD is not installed is simply skipped, and no plural is guessed.
RUNTIME_GROUPS=(kyriji.dev)
DATASTORE_GROUPS=(k8s.mariadb.com mongodbcommunity.mongodb.com redis.redis.opstreelabs.in)

step() { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
bad()  { echo -e "  ${RED}✗${NC} $*"; }

echo "=========================================="
echo "Uninstalling BMC"
echo "  namespace: $NAMESPACE"
echo "  profile:   $PROFILE"
[ "$PURGE" = 1 ] && echo "  purge:     the GameServer CRD will be REMOVED"
echo "=========================================="

if ! kubectl get ns >/dev/null 2>&1; then
  bad "no cluster reachable"
  exit 1
fi

# Delete every CR in the given API groups, waiting for finalizers to clear.
delete_crs() {
  local label="$1"; shift
  local found=0 r g
  for g in "$@"; do
    for r in $(kubectl api-resources --api-group="$g" --namespaced -o name 2>/dev/null); do
      local names
      names=$(kubectl get "$r" -n "$NAMESPACE" -o name 2>/dev/null || true)
      [ -z "$names" ] && continue
      found=1
      echo "  deleting $(echo "$names" | wc -l | tr -d ' ') $r"
      if ! kubectl delete "$r" --all -n "$NAMESPACE" --wait=true --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
        warn "$r did not finish within ${TIMEOUT}s -- continuing"
      fi
    done
  done
  [ "$found" = 0 ] && ok "no $label present"
  return 0
}

# ------------------------------------------------------- 1. runtime objects --
step "Removing runtime objects (Helm never owned these)"
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  delete_crs "GameServers" "${RUNTIME_GROUPS[@]}"
  if [ -n "$(kubectl get jobs -n "$NAMESPACE" -o name 2>/dev/null || true)" ]; then
    kubectl delete jobs --all -n "$NAMESPACE" --wait=true --timeout="${TIMEOUT}s" >/dev/null 2>&1 || true
    ok "jobs removed"
  else
    ok "no jobs present"
  fi
else
  ok "namespace $NAMESPACE does not exist"
fi

# --------------------------------------------------------- 2. datastore CRs --
step "Removing datastore resources while their operators still run"
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  delete_crs "datastore CRs" "${DATASTORE_GROUPS[@]}"
else
  ok "nothing to do"
fi

# ------------------------------------------------------- 3. helm releases ----
step "Destroying Helm releases"
if PROFILE="$PROFILE" helmfile destroy >/dev/null 2>&1; then
  ok "helmfile destroy completed"
else
  warn "helmfile destroy reported errors -- the sweep below is the backstop"
fi

# ----------------------------------------------------------- 4. namespaces --
step "Deleting namespaces"
for ns in "$NAMESPACE" "$OP_NAMESPACE"; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    if kubectl delete ns "$ns" --wait=true --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
      ok "$ns deleted"
    else
      bad "$ns did not terminate within ${TIMEOUT}s"
    fi
  else
    ok "$ns absent"
  fi
done

# ----------------------------------------------- 5. cluster-scoped sweep ----
# Namespace deletion cannot reach these. Swept by label so the list does not go
# stale as resources are added.
step "Sweeping cluster-scoped resources labelled $LABEL"
swept=0
for r in $(kubectl api-resources --namespaced=false --verbs=list,delete -o name 2>/dev/null); do
  # The GameServer CRD is resource-policy:keep on purpose: deleting it cascades
  # to every GameServer in the cluster. Only --purge takes it.
  if [ "$PURGE" = 0 ] && [ "$r" = "customresourcedefinitions.apiextensions.k8s.io" ]; then
    continue
  fi
  names=$(kubectl get "$r" -l "$LABEL" -o name 2>/dev/null || true)
  [ -z "$names" ] && continue
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    kubectl delete "$n" --ignore-not-found --timeout="${TIMEOUT}s" >/dev/null 2>&1 && echo "  deleted $n" && swept=$((swept+1))
  done <<< "$names"
done
[ "$swept" = 0 ] && ok "nothing left to sweep" || ok "$swept resource(s) swept"

# ---------------------------------------------------------- 6. verify -------
step "Verifying"
LEFTOVER=0

for ns in "$NAMESPACE" "$OP_NAMESPACE"; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    phase=$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
    bad "namespace $ns still exists (phase: $phase)"
    LEFTOVER=1
    if [ "$phase" = "Terminating" ]; then
      echo "     still holding finalizers:"
      kubectl get all,pvc -n "$ns" -o json 2>/dev/null \
        | jq -r '.items[]? | select((.metadata.finalizers // []) | length > 0)
                 | "       \(.kind)/\(.metadata.name)  finalizers=\(.metadata.finalizers | join(","))"' 2>/dev/null \
        || echo "       (install jq to list them)"
    fi
  else
    ok "namespace $ns gone"
  fi
done

remaining=""
for r in $(kubectl api-resources --namespaced=false --verbs=list -o name 2>/dev/null); do
  if [ "$PURGE" = 0 ] && [ "$r" = "customresourcedefinitions.apiextensions.k8s.io" ]; then
    continue
  fi
  found=$(kubectl get "$r" -l "$LABEL" -o name 2>/dev/null || true)
  [ -n "$found" ] && remaining="$remaining $found"
done
if [ -n "$remaining" ]; then
  bad "cluster-scoped resources still labelled $LABEL:"
  for n in $remaining; do echo "       $n"; done
  LEFTOVER=1
else
  ok "no cluster-scoped resources left"
fi

orphan_pvs=$(kubectl get pv -o jsonpath="{range .items[?(@.spec.claimRef.namespace==\"$NAMESPACE\")]}{.metadata.name}{\" \"}{end}" 2>/dev/null || true)
if [ -n "${orphan_pvs// /}" ]; then
  bad "PersistentVolumes still claimed by $NAMESPACE:"
  for pv in $orphan_pvs; do
    echo "       $pv ($(kubectl get pv "$pv" -o jsonpath='{.status.phase}/{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null))"
  done
  echo "     Retain-policy volumes are kept on purpose; delete them by hand if"
  echo "     you want the data gone."
  LEFTOVER=1
else
  ok "no PersistentVolumes left claimed by $NAMESPACE"
fi

if [ "$PURGE" = 0 ]; then
  if kubectl get crd gameservers.kyriji.dev >/dev/null 2>&1; then
    warn "GameServer CRD kept (resource-policy:keep). Use --purge to remove it."
  fi
fi

echo ""
if [ "$LEFTOVER" = 1 ]; then
  echo -e "${RED}=========================================="
  echo "Uninstall INCOMPLETE"
  echo -e "==========================================${NC}"
  echo ""
  echo "The resources above survived. Do NOT clear finalizers by hand:"
  echo "that deletes the object and orphans what it protected."
  exit 1
fi
echo -e "${GREEN}=========================================="
echo "Uninstall complete -- nothing left behind"
echo -e "==========================================${NC}"
echo ""
echo "Secrets lived in $NAMESPACE and went with it."
echo "Shared infrastructure (cert-manager, traefik, nfs) was NOT"
echo "touched; those namespaces are deliberately left for other workloads."
