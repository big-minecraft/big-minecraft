#!/bin/bash
set -euo pipefail

# Validate that the user has supplied the values BMC cannot guess.
#
# This checks CONFIGURATION only. Whether the cluster can actually satisfy the
# contract those values describe is preflight.sh's job.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHART_DIR="${CHART_DIR:-charts/bmc-chart}"
PROFILE="${PROFILE:-baremetal}"
VALUES_FILE="${VALUES_FILE:-${CONFIG_DIR:-config}/${PROFILE:-baremetal}.yaml}"
# Where BMC is installed. The Taskfile exports this; the fallback matches
# charts/bmc-chart/values.yaml so the script also works when run directly.
NAMESPACE="${NAMESPACE:-bmc}"

echo "=========================================="
echo "Validating Configuration"
echo "  profile: $PROFILE"
echo "=========================================="
echo ""

if ! command -v yq &> /dev/null; then
  echo -e "${RED}✗ yq is required${NC}"
  echo "   Install: https://github.com/mikefarah/yq#install"
  exit 1
fi

if [ ! -f "$VALUES_FILE" ]; then
  echo -e "${RED}✗ Configuration file not found: $VALUES_FILE${NC}"
  echo ""
  echo "Run: task config:init"
  exit 1
fi
echo -e "${GREEN}✓${NC} Found configuration file: $VALUES_FILE"

if [ ! -f "profiles/${PROFILE}.yaml" ]; then
  echo -e "${RED}✗ Unknown profile '${PROFILE}'${NC}. Available:"
  ls profiles/ | sed 's/\.yaml$//' | sed 's/^/     - /'
  exit 1
fi
echo -e "${GREEN}✓${NC} Using profile: profiles/${PROFILE}.yaml"
echo ""

# Resolve values through the same layering helmfile uses, so a value supplied
# by the profile counts as set.
merged() {
  yq eval-all '. as $item ireduce ({}; . * $item)' \
    "$CHART_DIR/values.yaml" "profiles/${PROFILE}.yaml" "$VALUES_FILE" 2>/dev/null
}
MERGED=$(merged)

VALIDATION_FAILED=false

# Shape, requiredness, enums and the conditional rules all live in
# charts/bmc-chart/values.schema.json, which Helm enforces on every render.
# Running it here fails `task install` at the config step rather than mid-deploy.
echo "Contract:"
echo ""
if SCHEMA_ERR=$(helm template bmc "$CHART_DIR" \
      -f "$CHART_DIR/values.yaml" -f "profiles/${PROFILE}.yaml" -f "$VALUES_FILE" \
      --api-versions "cert-manager.io/v1/ClusterIssuer" 2>&1 >/dev/null); then
  echo -e "${GREEN}✓${NC} values satisfy charts/bmc-chart/values.schema.json"
else
  echo -e "${RED}✗${NC} values do not satisfy charts/bmc-chart/values.schema.json:"
  # Conditional (allOf) rules report a vague '/global' line with the real key
  # indented beneath it, so keep both levels.
  echo "$SCHEMA_ERR" | grep -E "^(Error|[[:space:]]*- at )" | sed 's/^/   /'
  echo ""
  echo "   Each '- at' path is a key in $VALUES_FILE (or its profile)."
  VALIDATION_FAILED=true
fi

echo ""

# The panel host and the ingress host must agree or TLS will not match.
PANEL_HOST=$(echo "$MERGED" | yq '.global.panel.panelHost' - 2>/dev/null || echo "")
INGRESS_HOST=$(echo "$MERGED" | yq '.global.ingress.host' - 2>/dev/null || echo "")
if [ -n "$PANEL_HOST" ] && [ "$PANEL_HOST" != "null" ] && [ "$PANEL_HOST" != "$INGRESS_HOST" ]; then
  echo -e "${YELLOW}⚠${NC}  panel.panelHost ('$PANEL_HOST') differs from ingress.host ('$INGRESS_HOST')"
  echo "   The issued certificate will not match the address the panel is served on."
  echo ""
fi

# Changing host defeats the redis-service alias and breaks anything already
# resolving it, which is the thing the alias exists to prevent.
REDIS_EXTERNAL=$(echo "$MERGED" | yq '.global.redis.external' - 2>/dev/null || echo "false")
REDIS_HOST=$(echo "$MERGED" | yq '.global.redis.host' - 2>/dev/null || echo "")
if [ "$REDIS_EXTERNAL" = "true" ] && [ -n "$REDIS_HOST" ] && [ "$REDIS_HOST" != "redis-service" ]; then
  echo -e "${YELLOW}⚠${NC}  global.redis.host is '${REDIS_HOST}', not 'redis-service'"
  echo "   The chart keeps redis-service pointing at externalHost, so host"
  echo "   normally does not need to change."
  echo ""
fi

# ------------------------------------------------ stranded datastore volumes --
#
# Switching between "single" and "ha" is not a migration: the topologies use
# different storage, and Kubernetes never deletes a StatefulSet's claims. The
# Service name is identical in both, so the panel reconnects to an EMPTY
# database while the old volumes go on reserving disk -- surfacing much later
# as unschedulable storage somewhere unrelated.
echo ""
echo "Datastore volumes"
if ! kubectl get ns >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠${NC}  no cluster reachable -- skipping the stranded-volume check"
else
  PVCS=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}')
  STRANDED=""
  for DS in mariaDB mongoDB redis; do
    MODE=$(echo "$MERGED" | yq ".global.${DS}.mode" - 2>/dev/null | tr -d '"')
    case "$DS" in
      mariaDB) HA_PAT='^(storage|galera)-bmc-mariadb-[0-9]+$'; SINGLE_PAT='^mariadb-pvc$' ;;
      mongoDB) HA_PAT='^(data-volume|logs-volume)-bmc-mongodb-[0-9]+$'; SINGLE_PAT='^mongodb-pvc$' ;;
      redis)   HA_PAT='^bmc-redis-bmc-redis-[0-9]+$'; SINGLE_PAT='^redis-pvc$' ;;
    esac
    # Look for the volumes belonging to the mode that is NOT configured.
    if [ "$MODE" = "single" ]; then
      FOUND=$(echo "$PVCS" | grep -E "$HA_PAT" || true)
      OTHER="ha"
    elif [ "$MODE" = "ha" ]; then
      FOUND=$(echo "$PVCS" | grep -E "$SINGLE_PAT" || true)
      OTHER="single"
    else
      FOUND=""
    fi
    if [ -n "$FOUND" ]; then
      COUNT=$(echo "$FOUND" | wc -l | tr -d ' ')
      echo -e "${RED}✗${NC} ${DS} is set to '${MODE}', but this cluster already runs '${OTHER}'"
      echo "   ${COUNT} volume(s) from '${OTHER}' mode are still here:"
      echo "$FOUND" | sed 's/^/     /'
      STRANDED="${STRANDED}${FOUND}\n"
    fi
  done

  if [ -n "$STRANDED" ]; then
    # A hard stop: installing over a mode change succeeds silently against an
    # empty datastore, so this is the last point anyone sees it happening.
    echo ""
    echo "   Switching mode is NOT a migration. The Service name is identical in"
    echo "   both modes, so BMC will connect to a brand-new EMPTY datastore and"
    echo "   carry on, while the volumes above keep reserving disk forever."
    echo ""
    echo "   Pick one:"
    echo ""
    echo "   1. Keep your data -- in $VALUES_FILE, set each mode above back to"
    echo "      the one this cluster already runs."
    echo ""
    echo "   2. Abandon that data and reclaim the space (IRREVERSIBLE):"
    echo "        kubectl delete pvc -n $NAMESPACE <the names above>"
    echo "      then run this again."
    echo ""
    echo "   3. Migrate it yourself: dump from the old datastore, switch, restore."
    echo ""
    echo "   To proceed anyway and leave those volumes stranded, re-run with:"
    echo "        BMC_ALLOW_DATASTORE_MODE_CHANGE=true task install PROFILE=$PROFILE"
    if [ "${BMC_ALLOW_DATASTORE_MODE_CHANGE:-false}" = "true" ]; then
      echo ""
      echo -e "${YELLOW}⚠${NC}  BMC_ALLOW_DATASTORE_MODE_CHANGE=true -- continuing anyway"
    else
      VALIDATION_FAILED=true
    fi
  else
    echo -e "${GREEN}✓${NC} no datastore mode change detected"
  fi
fi

echo ""
if [ "$VALIDATION_FAILED" = true ]; then
  echo -e "${RED}=========================================="
  echo "Validation FAILED"
  echo -e "==========================================${NC}"
  echo ""
  echo "Edit $VALUES_FILE and fill the keys named above."
  exit 1
fi
echo -e "${GREEN}=========================================="
echo "Validation PASSED"
echo -e "==========================================${NC}"
echo ""
