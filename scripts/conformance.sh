#!/bin/bash
set -euo pipefail

# Render every profile and check the current cluster against the contract.
#
# The render half needs no cluster and is what CI runs on every commit: it
# catches a profile that references a value the templates no longer read, or a
# template that breaks under some profile's combination of settings.
#
# Pass --render-only to skip the live cluster probes.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHART_DIR="${CHART_DIR:-charts/bmc-chart}"
RENDER_ONLY=0
[ "${1:-}" = "--render-only" ] && RENDER_ONLY=1

# Capabilities the templates gate on. `helm template` has no cluster
# connection, so these must be declared or the guarded resources render empty.
API_VERSIONS=(
  --api-versions "metallb.io/v1beta1/IPAddressPool"
  --api-versions "metallb.io/v1beta1/L2Advertisement"
  --api-versions "cert-manager.io/v1/ClusterIssuer"
)

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=========================================="
echo "Conformance"
echo "=========================================="
echo ""

# ------------------------------------------------- platform chart renders ----
echo "Rendering bmc-chart against every profile"
for p in profiles/*.yaml; do
  name=$(basename "$p" .yaml)
  args=(-f "$CHART_DIR/values.yaml" -f "$p")
  # values.custom.yaml is gitignored, so CI renders without it.
  [ -f "$CHART_DIR/values.custom.yaml" ] && args+=(-f "$CHART_DIR/values.custom.yaml")

  if helm template bmc "$CHART_DIR" "${args[@]}" "${API_VERSIONS[@]}" > "$TMP/$name.yaml" 2>"$TMP/$name.err"; then
    lbs=$(grep -c "type: LoadBalancer" "$TMP/$name.yaml" || true)
    echo -e "  ${GREEN}✓${NC} $name ($(grep -c '^---' "$TMP/$name.yaml") docs, $lbs LoadBalancer)"
    # The whole point of the refactor: exactly one internet-facing Service.
    if [ "$lbs" -gt 1 ]; then
      echo -e "    ${RED}✗${NC} more than one LoadBalancer Service -- only the game edge should be one"
      grep -B12 "type: LoadBalancer" "$TMP/$name.yaml" | grep "^  name:" | sed 's/^/      /'
      FAILED=1
    fi
  else
    echo -e "  ${RED}✗${NC} $name failed to render"
    head -5 "$TMP/$name.err" | sed 's/^/      /'
    FAILED=1
  fi
done
echo ""

# -------------------------------------------------- runtime chart renders ----
echo "Rendering runtime charts (the panel installs these at deploy time)"
cat > "$TMP/fs.yaml" <<'EOF'
sftp: {podName: t, nodePort: 31000, pvcName: t, username: u, password: p}
fileSession: {podName: t, pvcName: t, mountPath: /minecraft}
activityWatcher: {panelUrl: http://panel-service, serviceToken: t, sessionId: s}
EOF
for pair in "proxy-chart:default-values/proxy.yaml" \
            "scalable-deployment-chart:default-values/scalable.yaml" \
            "persistent-deployment-chart:default-values/persistent.yaml" \
            "process-chart:default-values/process.yaml" \
            "file-session-chart:$TMP/fs.yaml"; do
  chart="chart-templates/${pair%%:*}"
  vals="${pair##*:}"
  if helm template t "$chart" -f "$vals" > "$TMP/rt.yaml" 2>"$TMP/rt.err"; then
    echo -e "  ${GREEN}✓${NC} $(basename "$chart")"
  else
    echo -e "  ${RED}✗${NC} $(basename "$chart")"
    head -3 "$TMP/rt.err" | sed 's/^/      /'
    FAILED=1
  fi
done
echo ""

# ------------------------------------------------------------ live cluster --
if [ "$RENDER_ONLY" = "1" ]; then
  echo "Skipping cluster probes (--render-only)"
else
  echo "Checking the live cluster against the contract"
  echo "  context: $(kubectl config current-context 2>/dev/null || echo '<none>')"
  echo ""
  if ! "$(dirname "$0")/preflight.sh"; then
    FAILED=1
  fi
fi

echo "=========================================="
if [ "$FAILED" = "1" ]; then
  echo -e "${RED}Conformance FAILED${NC}"
  echo "=========================================="
  exit 1
fi
echo -e "${GREEN}Conformance PASSED${NC}"
echo "=========================================="
