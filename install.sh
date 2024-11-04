#!/bin/bash

# Create values directory if it doesn't exist
mkdir -p values

# Prompt for values
echo "Please enter your domain (e.g., web.example.com):"
read domain

echo "Please enter your IP address (e.g., 123.456.789.0):"
read ip_address

# Validate IP address format
if [[ ! $ip_address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid IP address format"
    exit 1
fi

# Create or update values/global.yaml
cat > values/global.yaml << EOF
domain: $domain
loadBalancerIP: $ip_address
EOF

echo "Created values/global.yaml with:"
echo "Domain: $domain"
echo "IP: $ip_address"
echo "------------------------"
echo "Proceeding with installation..."
echo "------------------------"

# Continue with installation
./scripts/install-dependents.sh
helm uninstall traefik traefik-crd -n kube-system || true  # Added || true to continue if uninstall fails
helmfile apply -l name="metallb"
helmfile apply -l name="cert-manager"
helmfile apply
helmfile sync

echo "------------------------"
echo "Installation complete!"
echo "Your application should be accessible at: https://$domain"