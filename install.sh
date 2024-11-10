#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Create values directory if it doesn't exist
mkdir -p values

# Prompt for values
echo "Please enter your panel domain (e.g., panel.example.com):"
read panel_domain

echo "Please enter your Kubernetes dashboard domain (e.g., k8s.example.com):"
read k8s_dashboard_domain

echo "Please enter your IP address (e.g., 123.456.789.0):"
read ip_address

# Validate IP address format
if [[ ! $ip_address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid IP address format"
    exit 1
fi

# Generate random invite code if it doesn't exist
generate_invite_code() {
    openssl rand -base64 9 | tr -dc 'a-zA-Z0-9' | head -c 12
}

# Read existing values if file exists
if [ -f values/global.yaml ]; then
    existing_invite_code=$(grep "inviteCode:" values/global.yaml | awk '{print $2}' | tr -d '"')
fi

# If invite code is empty or doesn't exist, generate a new one
if [ -z "$existing_invite_code" ] || [ "$existing_invite_code" = "''" ]; then
    invite_code=$(generate_invite_code)
else
    invite_code=$existing_invite_code
fi

# Create or update values/global.yaml
cat > values/global.yaml << EOF
panelDomain: $panel_domain
k8sDashboardDomain: $k8s_dashboard_domain
loadBalancerIP: $ip_address
inviteCode: $invite_code
EOF

echo "Created values/global.yaml with:"
echo "Panel Domain: $panel_domain"
echo "K8s Dashboard Domain: $k8s_dashboard_domain"
echo "IP: $ip_address"
echo "Invite Code: $invite_code"
echo "------------------------"
echo "Proceeding with installation..."
echo "------------------------"

# Continue with installation
./scripts/install-dependents.sh
helm uninstall traefik traefik-crd -n kube-system || true

# Add a small delay to ensure the CRDs are removed
sleep 5

helmfile apply -l name="metallb"
helmfile apply -l name="cert-manager"
helmfile apply
helmfile sync

echo "------------------------"
echo "Installation complete!"
echo "Your panel should be accessible at: https://$panel_domain"
echo "Your Kubernetes dashboard should be accessible at: https://$k8s_dashboard_domain"
echo "Your invite code is: $invite_code"
echo "Please save this invite code for future reference."