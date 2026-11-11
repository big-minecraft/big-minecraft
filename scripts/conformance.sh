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
  --api-versions "cert-manager.io/v1/ClusterIssuer" \
  --api-versions "traefik.io/v1alpha1"
)

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=========================================="
echo "Conformance"
echo "=========================================="
echo ""

# ------------------------------------------------- platform chart renders ----
# The keys values.schema.json requires an operator to supply. Filling them here
# stands in for config/<profile>.yaml, which is gitignored: conformance checks
# the layers this repo ships, not whatever is on one machine.
cat > "$TMP/fill.yaml" <<'EOF'
global:
  certManager: {email: "conformance@bmc.test"}
  panel: {panelHost: "panel.bmc.test"}
  ingress: {host: "panel.bmc.test"}
EOF
MUST_SUPPLY="/global/certManager/email /global/ingress/host /global/panel/panelHost"
# Keys a template deliberately sets to something other than the merged default.
TEMPLATE_OWNED="global.certManager.installClusterIssuer \
global.storage.classes.shared.name \
global.storage.classes.database.name \
global.storage.classes.persistent.name"

echo "Rendering bmc-chart against every profile"
for p in profiles/*.yaml; do
  name=$(basename "$p" .yaml)
  args=(-f "$CHART_DIR/values.yaml" -f "$p")
  [ -f "${CONFIG_DIR:-config}/templates/$name.yaml" ] && args+=(-f "${CONFIG_DIR:-config}/templates/$name.yaml")
  args+=(-f "$TMP/fill.yaml")

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

# ----------------------------------------------------- config templates ------
echo "Checking the config contract"
for p in profiles/*.yaml; do
  name=$(basename "$p" .yaml)
  tpl="${CONFIG_DIR:-config}/templates/$name.yaml"

  if [ ! -f "$tpl" ]; then
    echo -e "  ${RED}✗${NC} $name has no $tpl -- task config:init cannot run for it"
    FAILED=1
    continue
  fi

  # An untouched template must fail the schema on exactly the keys an operator
  # has to supply. Fewer means the template pre-fills something it should ask
  # for; more means a profile stopped supplying something.
  # helm is expected to fail here, so the non-zero exit must not trip set -e.
  got=$({ helm template t "$CHART_DIR" -f "$CHART_DIR/values.yaml" -f "$p" -f "$tpl" \
            "${API_VERSIONS[@]}" 2>&1 >/dev/null || true; } \
        | sed -n "s/^[[:space:]]*- at '\([^']*\)'.*/\1/p" \
        | grep -v '^/global$' | sort -u | tr '\n' ' ')
  want=$(echo "$MUST_SUPPLY" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  if [ "$got" != "$want" ]; then
    echo -e "  ${RED}✗${NC} $name template+profile does not leave exactly the must-supply keys open"
    echo "      open:     ${got:-<none>}"
    echo "      expected: $want"
    FAILED=1
    continue
  fi

  # Filled in, the same layers must render.
  if ! helm template t "$CHART_DIR" -f "$CHART_DIR/values.yaml" -f "$p" -f "$tpl" \
         -f "$TMP/fill.yaml" "${API_VERSIONS[@]}" >/dev/null 2>"$TMP/ct.err"; then
    echo -e "  ${RED}✗${NC} $name template+profile fails to render once filled"
    head -3 "$TMP/ct.err" | sed 's/^/      /'
    FAILED=1
    continue
  fi

  # A template value is layer 3, so it pins. Every one must equal what
  # values.yaml+profile already resolves to -- otherwise a default that moves
  # gets silently overridden in every config made from this template.
  if command -v yq >/dev/null 2>&1; then
    yq -o=props "$tpl" 2>/dev/null | grep -E '^[A-Za-z]' | sort > "$TMP/t.props"
    yq ea '. as $i ireduce ({}; . * $i)' "$CHART_DIR/values.yaml" "$p" 2>/dev/null \
      | yq -o=props - 2>/dev/null | grep -E '^[A-Za-z]' | sort > "$TMP/b.props"
    drift=""
    while IFS= read -r line; do
      key=${line%% = *}
      case " $TEMPLATE_OWNED " in *" $key "*) continue ;; esac
      base=$(awk -F' = ' -v k="$key" '$1==k {print; exit}' "$TMP/b.props")
      [ "$line" = "$base" ] || drift="$drift $key"
    done < "$TMP/t.props"
    if [ -n "$drift" ]; then
      echo -e "  ${RED}✗${NC} $name template diverges from values.yaml+profile:$drift"
      echo "      match the template to the default, or add the key to TEMPLATE_OWNED"
      FAILED=1
      continue
    fi
  fi

  echo -e "  ${GREEN}✓${NC} $name"
done
echo ""

# -------------------------------------------------- runtime chart renders ----
echo "Rendering runtime charts (the panel installs these at deploy time)"
cat > "$TMP/fs.yaml" <<'EOF'
sftp: {podName: t, nodePort: 31000, pvcName: t, username: u, password: p}
fileSession: {podName: t, pvcName: t, mountPath: /minecraft}
activityWatcher: {panelUrl: http://panel-service, serviceToken: t, sessionId: s}
EOF
cat > "$TMP/publish.yaml" <<'EOF'
publish: {jobName: p, deploymentName: proxy, version: v1, pvcName: t, mountPath: /minecraft}
EOF
# These charts are separate Helm releases, so they get no `global` from
# bmc-chart -- the panel injects it at render time from GLOBAL_VALUES_JSON,
# which is `.Values.global` of this chart verbatim. Passing this chart's own
# values.yaml below is this script standing in for the panel, and means the
# render is checked against the real contract rather than a second copy of it
# that could drift.
#
# Only the storage class names are overridden here. They are empty in
# values.yaml on purpose -- no name is right for every cluster -- and
# validate-config.sh is what fails an install that left one unset. Naming them
# here keeps the rendered PVCs realistic; without it they would render with an
# empty storageClassName, which is valid YAML and would hide nothing useful.
cat > "$TMP/injected.yaml" <<'EOF'
global:
  storage:
    classes:
      shared: {name: conformance-rwx, accessMode: ReadWriteMany}
      database: {name: conformance-block, accessMode: ReadWriteOnce}
      persistent: {name: conformance-rwx, accessMode: ReadWriteMany}
EOF
for pair in "artifact-publish-chart:$TMP/publish.yaml" \
            "proxy-chart:charts/bmc-chart/files/default-values/proxy.yaml" \
            "scalable-deployment-chart:charts/bmc-chart/files/default-values/scalable.yaml" \
            "persistent-deployment-chart:charts/bmc-chart/files/default-values/persistent.yaml" \
            "process-chart:charts/bmc-chart/files/default-values/process.yaml" \
            "file-session-chart:$TMP/fs.yaml"; do
  chart="charts/bmc-chart/files/chart-templates/${pair%%:*}"
  vals="${pair##*:}"
  if helm template t "$chart" -f "$CHART_DIR/values.yaml" -f "$TMP/injected.yaml" \
       -f "$vals" > "$TMP/rt.yaml" 2>"$TMP/rt.err"; then
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
