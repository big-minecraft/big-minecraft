#!/bin/bash
set -euo pipefail

# Print connection details for open SFTP / file-edit sessions.
#
# Why this exists: the panel advertises "sftp://<panelHost>:<sftpPort>", which
# assumes the panel hostname reaches a cluster node on that NodePort. That holds
# on bare metal and does not hold on a cloud LoadBalancer edge, where each
# session gets its own load balancer at a hostname the panel never shows. Until
# bmc-panel reads that hostname itself, this reads it for you.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="${NAMESPACE:-bmc}"

SERVICES=$(kubectl get svc -n "$NAMESPACE" -o name 2>/dev/null | grep '/sftp-' || true)

if [ -z "$SERVICES" ]; then
  echo -e "${YELLOW}No open file sessions in namespace '$NAMESPACE'.${NC}"
  echo "Open one from the panel first; sessions expire after"
  echo "global.fileEditSession.timeoutMinutes (default 15)."
  exit 0
fi

echo ""
echo "=========================================="
echo "Open SFTP sessions"
echo "=========================================="

for svc in $SERVICES; do
  name="${svc#service/}"
  type=$(kubectl get "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null)

  case "$type" in
    LoadBalancer)
      addr=$(kubectl get "$svc" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
      port=22
      ;;
    NodePort)
      addr=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
      [ -z "$addr" ] && addr=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
      port=$(kubectl get "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
      ;;
    *)
      addr=""; port=""
      ;;
  esac

  echo ""
  echo "  session:  $name  (Service type: $type)"
  if [ -z "$addr" ]; then
    echo -e "  ${YELLOW}address not assigned yet -- the load balancer may still be provisioning${NC}"
  else
    echo -e "  ${GREEN}sftp://${addr}:${port}${NC}"
  fi
  echo "  username: from the panel's session view"
  echo "  password: kubectl get secret bmc-secrets -n $NAMESPACE -o jsonpath='{.data.sftp-password}' | base64 -d"
done

echo ""
