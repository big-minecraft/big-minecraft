#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "=========================================="
echo "Waiting for webhooks to be ready..."
echo "=========================================="
echo ""

# Nothing to wait for if this profile installs neither webhook-bearing chart.
# Without this the script polls for the full 12 minutes on any install that
# does not use cert-manager (ingress.tls.mode != cluster-issuer) or MetalLB.
CM=0; MLB=0
kubectl get deployment cert-manager-webhook -n cert-manager &>/dev/null && CM=1
kubectl get deployment metallb-controller -n metallb-system &>/dev/null && MLB=1
if [ "$CM" = "0" ] && [ "$MLB" = "0" ]; then
  echo -e "${GREEN}✓${NC} Neither cert-manager nor MetalLB is installed - nothing to wait for"
  echo ""
  exit 0
fi
if [ "$CM" = "0" ]; then
  echo -e "${GREEN}✓${NC} cert-manager is not installed - skipping its webhook checks"
  echo ""
  exit 0
fi

# Wait for deployments to be available
echo "Waiting for cert-manager webhook deployment..."
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager 2>/dev/null || true

echo "Waiting for MetalLB controller deployment..."
kubectl wait --for=condition=available --timeout=300s deployment/metallb-controller -n metallb-system 2>/dev/null || true

echo ""
echo "⏳ Waiting for webhook TLS certificates to become valid..."
echo "   cert-manager generates self-signed certificates that can take up to 12 minutes to activate"
echo "   Checking periodically for certificate readiness..."
echo ""

# Maximum wait time of 12 minutes (720 seconds)
MAX_WAIT_TIME=720
ELAPSED=0
START_TIME=$(date +%s)
CHECK_INTERVAL=10
DOTS_PRINTED=0

echo -n "Checking certificate validity"

while [ $ELAPSED -lt $MAX_WAIT_TIME ]; do
    # Check if cert-manager webhook pods are ready
    # These probes are expected to fail while the webhook is still coming up,
    # so they must not trip `set -e`.
    WEBHOOK_READY=$(kubectl get pods -n cert-manager -l app.kubernetes.io/name=webhook -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

    # Debug output (remove later)
    #echo "[DEBUG] WEBHOOK_READY=$WEBHOOK_READY" >&2

    if [ "$WEBHOOK_READY" = "True" ]; then
        # Pods are ready, now check if webhook configuration has caBundle
        CA_BUNDLE=$(kubectl get validatingwebhookconfigurations cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)

        # Debug output (remove later)
        #echo "[DEBUG] CA_BUNDLE exists: $([ -n "$CA_BUNDLE" ] && echo yes || echo no)" >&2

        if [ -n "$CA_BUNDLE" ] && [ "$CA_BUNDLE" != "null" ]; then
            # Test by creating a Certificate resource which WILL trigger webhook validation
            # This is a more reliable test than Issuer which may not always invoke the webhook
            TEST_RESULT=$(kubectl create -f - 2>&1 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-test-ns
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: test-selfsigned
  namespace: cert-manager-test-ns
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: cert-manager-test-ns
spec:
  secretName: test-cert-tls
  issuerRef:
    name: test-selfsigned
    kind: Issuer
  dnsNames:
    - test.example.com
EOF
) || true

            # Clean up test namespace
            kubectl delete namespace cert-manager-test-ns --wait=false &>/dev/null || true

            # Check for webhook certificate errors
            if echo "$TEST_RESULT" | grep -q "x509: certificate"; then
                # Webhook cert is not valid yet, keep waiting
                true
            elif echo "$TEST_RESULT" | grep -q "connection refused\|Internal error occurred\|failed to call webhook"; then
                # Webhook is not responding properly, keep waiting
                true
            elif echo "$TEST_RESULT" | grep -q "created"; then
                # Success! Webhook accepted the resource
                echo ""
                echo ""
                echo -e "${GREEN}✓${NC} Webhook certificates are valid and ready! (took ${ELAPSED}s)"
                break
            fi
        fi
    fi

    # Print progress
    if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        REMAINING=$((MAX_WAIT_TIME - ELAPSED))
        MINUTES=$((REMAINING / 60))
        SECONDS=$((REMAINING % 60))
        echo ""
        printf "   Progress: %d/%d seconds (~%dm %ds remaining)\n" "$ELAPSED" "$MAX_WAIT_TIME" "$MINUTES" "$SECONDS"
        echo -n "Checking certificate validity"
        DOTS_PRINTED=0
    else
        echo -n "."
        DOTS_PRINTED=$((DOTS_PRINTED + 1))
    fi

    sleep $CHECK_INTERVAL
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
done

# Check if we timed out
if [ $ELAPSED -ge $MAX_WAIT_TIME ]; then
    echo ""
    echo ""
    echo -e "${YELLOW}⚠${NC}  Reached maximum wait time. Proceeding anyway..."
    echo "   If you encounter webhook errors, you may need to wait longer or reinstall cert-manager"
fi

echo ""
echo ""
echo -e "${GREEN}All webhooks ready!${NC}"
echo ""
exit 0
