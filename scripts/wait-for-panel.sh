#!/bin/bash
set -euo pipefail

# Wait for the panel to actually be serving, then print where it lives.
#
# `helmfile apply` returning only means the manifests were accepted. The panel
# sits behind an init container that waits out the datastores, so on a fresh
# install it is routinely several minutes from applied to answering -- and
# `task install` used to finish and leave the operator guessing. This blocks on
# the readinessProbe in charts/bmc-chart/templates/panel.yaml, which is the
# same condition that puts the pod into panel-service's endpoints.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHART_DIR="${CHART_DIR:-charts/bmc-chart}"
PROFILE="${PROFILE:-baremetal}"
VALUES_FILE="${VALUES_FILE:-${CONFIG_DIR:-config}/${PROFILE}.yaml}"
NAMESPACE="${NAMESPACE:-bmc}"
# A cold install waits on the datastores first (the init container gives them
# ten minutes), so this has to outlast that rather than race it.
TIMEOUT="${PANEL_WAIT_TIMEOUT:-900}"

echo ""
echo "=========================================="
echo "Waiting for the panel to come up..."
echo "=========================================="
echo ""

if ! kubectl get deployment panel -n "$NAMESPACE" &>/dev/null; then
  echo -e "${RED}✗${NC} No 'panel' deployment in namespace '$NAMESPACE'"
  echo "   Run 'task deploy-bmc PROFILE=$PROFILE' first."
  exit 1
fi

echo "   deployment/panel in $NAMESPACE (timeout ${TIMEOUT}s)"
echo "   the init container waits for MariaDB, MongoDB and Redis first, so this"
echo "   can sit here for a few minutes on a cold install."
echo ""

# rollout status is the honest wait: it returns when the new ReplicaSet's pods
# pass their readinessProbe, not merely when the object exists.
if ! kubectl rollout status deployment/panel -n "$NAMESPACE" --timeout="${TIMEOUT}s"; then
  echo ""
  echo -e "${RED}✗${NC} The panel did not become ready within ${TIMEOUT}s."
  echo ""
  echo "   What it is doing:"
  echo "     kubectl get pods -n $NAMESPACE -l app=panel"
  echo "     kubectl describe pod -n $NAMESPACE -l app=panel"
  echo "     kubectl logs -n $NAMESPACE -l app=panel -c wait-for-datastores"
  echo "     kubectl logs -n $NAMESPACE -l app=panel -c panel"
  echo ""
  echo "   Raise the limit with PANEL_WAIT_TIMEOUT=<seconds> if the cluster is"
  echo "   just slow rather than broken."
  exit 1
fi

# Where to send them. Resolved through the same layering helmfile uses, so a
# host supplied by the profile counts as set.
URL=""
if command -v yq &>/dev/null && [ -f "$VALUES_FILE" ]; then
  MERGED=$(yq eval-all '. as $item ireduce ({}; . * $item)' \
    "$CHART_DIR/values.yaml" "profiles/${PROFILE}.yaml" "$VALUES_FILE" 2>/dev/null || true)
  get() { printf '%s' "$MERGED" | yq -r "$1" 2>/dev/null | sed 's/^null$//'; }

  HOST=$(get '.global.ingress.host')
  [ -n "$HOST" ] || HOST=$(get '.global.panel.panelHost')
  # Anything but "none" means the Ingress terminates TLS for this host.
  TLS_MODE=$(get '.global.ingress.tls.mode')
  [ -n "$TLS_MODE" ] || TLS_MODE="none"

  if [ -n "$HOST" ]; then
    if [ "$TLS_MODE" = "none" ]; then
      URL="http://${HOST}"
    else
      URL="https://${HOST}"
    fi
  fi
fi

echo ""
echo -e "${GREEN}✓ The panel is up.${NC}"
echo ""
if [ -n "$URL" ]; then
  echo -e "   ${GREEN}${URL}${NC}"
  echo ""
  # Readiness is answered from inside the cluster. DNS pointing at the edge and
  # a certificate actually being issued are separate problems, and saying "it is
  # up" without this note sends people hunting the panel for an edge fault.
  echo "   That is the Ingress host from your config. If it does not load yet,"
  echo "   check that its DNS points at this cluster's edge"
  if [ "$TLS_MODE" = "cluster-issuer" ]; then
    echo "   and that cert-manager has issued the certificate:"
    echo "     kubectl get certificate -n $NAMESPACE"
  else
    echo "   -- the panel itself is ready either way."
  fi
else
  echo -e "   ${YELLOW}⚠${NC}  Could not resolve the panel's host from $VALUES_FILE."
  echo "   Reach it directly with:"
  echo "     kubectl port-forward -n $NAMESPACE svc/panel-service 8080:80"
  echo "     http://localhost:8080"
fi
echo ""
exit 0
