#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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

# Generate random invite code if it doesn't exist
generate_invite_code() {
    # Use openssl instead of /dev/urandom for better compatibility
    openssl rand -base64 9 | tr -dc 'a-zA-Z0-9' | head -c 12
}

# Read existing values if file exists
if [ -f values/global.yaml ]; then
    existing_invite_code=$(grep "inviteCode:" values/global.yaml | awk '{print $2}')
fi

# If invite code is empty or doesn't exist, generate a new one
if [ -z "$existing_invite_code" ] || [ "$existing_invite_code" = '""' ] || [ "$existing_invite_code" = "''" ]; then
    invite_code=$(generate_invite_code)
else
    invite_code=$existing_invite_code
fi

# Create or update values/global.yaml
cat > values/global.yaml << EOF
domain: $domain
loadBalancerIP: $ip_address
inviteCode: "$invite_code"
EOF

echo "Created values/global.yaml with:"
echo "Domain: $domain"
echo "IP: $ip_address"
echo "Invite Code: $invite_code"
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
echo "Your invite code is: $invite_code"
echo "Please save this invite code for future reference."