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
PROFILE="${PROFILE:-baremetal-metallb}"
VALUES_FILE="${VALUES_FILE:-$CHART_DIR/values.custom.yaml}"

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

check_value() {
  local path="$1" description="$2" example="${3:-}"
  local value
  value=$(echo "$MERGED" | yq "$path" - 2>/dev/null || echo "")

  if [ -z "$value" ] || [ "$value" = "null" ] || [ "$value" = '""' ] \
     || [[ "$value" == *"CHANGE"* ]] || [[ "$value" == *"example.com"* ]] \
     || [[ "$value" == *"your-email"* ]]; then
    echo -e "${RED}✗${NC} Missing: $description"
    echo "   Path: $path"
    [ -n "$example" ] && echo "   Example: $example"
    VALIDATION_FAILED=true
  else
    echo -e "${GREEN}✓${NC} $description: $value"
  fi
}

echo "Required configuration:"
echo ""
check_value '.global.certManager.email' "Let's Encrypt email" "admin@yourdomain.com"
check_value '.global.panel.panelHost'   "Panel host"          "panel.yourdomain.com"
check_value '.global.ingress.host'      "Panel ingress host"  "panel.yourdomain.com"
check_value '.global.ingress.className' "Ingress class"       "traefik"

# The panel host and the ingress host must agree or TLS will not match.
PANEL_HOST=$(echo "$MERGED" | yq '.global.panel.panelHost' - 2>/dev/null || echo "")
INGRESS_HOST=$(echo "$MERGED" | yq '.global.ingress.host' - 2>/dev/null || echo "")
if [ -n "$PANEL_HOST" ] && [ "$PANEL_HOST" != "null" ] && [ "$PANEL_HOST" != "$INGRESS_HOST" ]; then
  echo -e "${YELLOW}⚠${NC}  panel.panelHost ('$PANEL_HOST') differs from ingress.host ('$INGRESS_HOST')"
  echo "   The issued certificate will not match the address the panel is served on."
fi

echo ""
echo "Storage:"
echo ""
check_value '.global.storage.classes.shared.name'   "Shared storage class (RWX)" "longhorn"
check_value '.global.storage.classes.database.name' "Database storage class"     "longhorn"

# The shared class can only be ReadWriteOnce because instances pull artifacts
# instead of mounting it. With artifacts off they mount it directly, and an RWO
# volume attaches to one node -- the resulting multi-attach errors read like a
# scheduling problem.
ARTIFACTS_ON=$(echo "$MERGED" | yq '.global.artifactStore.enabled' - 2>/dev/null || echo "false")
SHARED_MODE=$(echo "$MERGED" | yq '.global.storage.classes.shared.accessMode' - 2>/dev/null || echo "")
if [ "$SHARED_MODE" = "ReadWriteOnce" ] && [ "$ARTIFACTS_ON" != "true" ]; then
  echo -e "${RED}✗${NC} shared storage is ReadWriteOnce but artifactStore.enabled is false"
  echo "   Instances would still mount that volume, and a ReadWriteOnce volume"
  echo "   attaches to one node -- so a deployment cannot outgrow a single node."
  echo "   Either enable the artifact store, or set the shared class to"
  echo "   ReadWriteMany."
  VALIDATION_FAILED=true
else
  echo -e "${GREEN}✓${NC} Shared storage: ${SHARED_MODE} with artifacts $([ "$ARTIFACTS_ON" = "true" ] && echo enabled || echo disabled)"
fi

# ReadWriteMany is only required for persistent deployments now: their server
# runs in place while a file session can mount the same volume. Everything else
# pulls artifacts into a pod-local emptyDir.
USES_PERSISTENT=$(echo "$MERGED" | yq '.global.storage.persistentDeployments' - 2>/dev/null || echo "true")
if [ "$USES_PERSISTENT" = "true" ]; then
  check_value '.global.storage.classes.persistent.name' "Persistent storage class (RWX)" "longhorn"
  PERSISTENT_MODE=$(echo "$MERGED" | yq '.global.storage.classes.persistent.accessMode' - 2>/dev/null || echo "")
  if [ "$PERSISTENT_MODE" != "ReadWriteMany" ]; then
    echo -e "${RED}✗${NC} storage.classes.persistent.accessMode is '$PERSISTENT_MODE', must be ReadWriteMany"
    echo "   A persistent deployment's server runs in place while a file session"
    echo "   can mount the same volume, so two pods hold it at once."
    VALIDATION_FAILED=true
  fi
else
  echo -e "${GREEN}✓${NC} No persistent deployments -- ReadWriteMany not required"
fi

# An external Redis needs somewhere to point. The chart keeps the
# redis-service name resolvable either way, so global.redis.host should NOT
# change -- the endpoint goes in externalHost.
REDIS_EXTERNAL=$(echo "$MERGED" | yq '.global.redis.external' - 2>/dev/null || echo "false")
REDIS_HOST=$(echo "$MERGED" | yq '.global.redis.host' - 2>/dev/null || echo "")
REDIS_EXT_HOST=$(echo "$MERGED" | yq '.global.redis.externalHost' - 2>/dev/null || echo "")
if [ "$REDIS_EXTERNAL" = "true" ]; then
  if [ -z "$REDIS_EXT_HOST" ] || [ "$REDIS_EXT_HOST" = "null" ] || [ "$REDIS_EXT_HOST" = '""' ]; then
    echo -e "${RED}✗${NC} global.redis.external is true but externalHost is not set"
    echo "   Set global.redis.externalHost to your Redis endpoint (hostname or IP)."
    VALIDATION_FAILED=true
  else
    echo -e "${GREEN}✓${NC} External Redis: ${REDIS_EXT_HOST} (via the redis-service alias)"
  fi
  # Changing host defeats the alias and breaks anything already resolving
  # redis-service, which is the thing the alias exists to prevent.
  if [ -n "$REDIS_HOST" ] && [ "$REDIS_HOST" != "redis-service" ]; then
    echo -e "${YELLOW}⚠${NC}  global.redis.host is '${REDIS_HOST}', not 'redis-service'"
    echo "   The chart keeps redis-service pointing at externalHost, so host"
    echo "   normally does not need to change. Anything already resolving"
    echo "   redis-service will not follow this."
  fi
fi

echo ""
echo "Edge:"
echo ""
EDGE_TYPE=$(echo "$MERGED" | yq '.global.edge.game.type' - 2>/dev/null || echo "")
echo -e "${GREEN}✓${NC} Game edge type: $EDGE_TYPE"

# An SFTP session is a credentialed door into game data, and the Service's
# loadBalancerSourceRanges is the ONLY thing gating who can knock on it.
#
# On a cloud load balancer an empty list does not mean "closed", it means
# "0.0.0.0/0": the chart omits loadBalancerSourceRanges entirely, and the
# provider's controller then opens the listener to the whole internet. That is
# the opposite of the safe default it looks like, so it is a hard failure here
# rather than a warning.
FILE_EDGE_TYPE=$(echo "$MERGED" | yq '.global.edge.file.type' - 2>/dev/null || echo "")
FILE_RANGES=$(echo "$MERGED" | yq '.global.edge.file.sourceRanges | length' - 2>/dev/null || echo "0")
if [ "$FILE_EDGE_TYPE" = "LoadBalancer" ]; then
  if [ "${FILE_RANGES:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${GREEN}✓${NC} File session edge: LoadBalancer, restricted to ${FILE_RANGES} source range(s)"
  else
    echo -e "${RED}✗${NC} global.edge.file.sourceRanges is empty with edge.file.type=LoadBalancer"
    echo "   Every open SFTP session would be reachable from the whole internet."
    echo "   Set it to your operators' addresses, e.g.:"
    echo "     global.edge.file.sourceRanges: [\"203.0.113.4/32\"]"
    VALIDATION_FAILED=true
  fi
else
  echo -e "${GREEN}✓${NC} File session edge type: $FILE_EDGE_TYPE"
fi

# MetalLB resources need an address pool; nothing else does.
INSTALL_METALLB=$(echo "$MERGED" | yq '.global.metallb.installResources' - 2>/dev/null || echo "false")
if [ "$INSTALL_METALLB" = "true" ]; then
  POOL_LEN=$(echo "$MERGED" | yq '.global.metallb.ipAddressPool | length' - 2>/dev/null || echo "0")
  if [ "$POOL_LEN" -eq 0 ] 2>/dev/null; then
    echo -e "${RED}✗${NC} Missing: MetalLB IP address pool"
    echo "   Path: .global.metallb.ipAddressPool"
    echo "   Example: [\"192.168.1.100/32\"]"
    VALIDATION_FAILED=true
  else
    echo -e "${GREEN}✓${NC} MetalLB IP pool: $(echo "$MERGED" | yq -o=json -I=0 '.global.metallb.ipAddressPool' - 2>/dev/null)"
  fi
fi

echo ""
if [ "$VALIDATION_FAILED" = true ]; then
  echo -e "${RED}=========================================="
  echo "Validation FAILED"
  echo -e "==========================================${NC}"
  echo ""
  echo "Edit $VALUES_FILE and set the values marked ✗."
  exit 1
fi
echo -e "${GREEN}=========================================="
echo "Validation PASSED"
echo -e "==========================================${NC}"
echo ""
