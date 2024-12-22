#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (with sudo)"
    exit 1
fi

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Set full permissions (rwx) recursively for the script directory
chmod -R 777 "$SCRIPT_DIR"

# Function to find kubernetes config path
find_kube_config() {
    # Check common locations for kubernetes config
    possible_paths=(
        "/etc/rancher/k3s/k3s.yaml"
        "$HOME/.kube/config"
        "/etc/kubernetes/admin.conf"
        "/etc/kubernetes/kubeconfig"
    )
    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    # If no config found, return empty
    echo ""
    return 1
}

# Get BMC path (directory containing this script)
bmc_path="$SCRIPT_DIR"

# Find and export KUBECONFIG
KUBECONFIG=$(find_kube_config)
if [ -z "$KUBECONFIG" ]; then
    echo "Error: Could not find Kubernetes config file"
    exit 1
fi
export KUBECONFIG

# Initialize local directory
"$SCRIPT_DIR/scripts/initialize-local.sh"

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

# Generate random invite code
generate_invite_code() {
    openssl rand -base64 9 | tr -dc 'a-zA-Z0-9' | head -c 12
}

# Generate random MariaDB password
generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*()' | head -c 20
}

# Always generate new strings
invite_code=$(generate_invite_code)
mariadb_password=$(generate_password)
mongodb_password=$(generate_password)

# Create or update local/global-config.yaml
cat > local/global-config.yaml << EOF
panelDomain: $panel_domain
k8sDashboardDomain: $k8s_dashboard_domain
loadBalancerIP: $ip_address
inviteCode: $invite_code
mariaDBPassword: $mariadb_password
mongoDBPassword: $mongodb_password
clusterConfigPath: $KUBECONFIG
bmcPath: $bmc_path
EOF

echo "Created local/global-config.yaml with:"
echo "Panel Domain: $panel_domain"
echo "K8s Dashboard Domain: $k8s_dashboard_domain"
echo "IP: $ip_address"
echo "Invite Code: $invite_code"
echo "MariaDB Password: $mariadb_password"
echo "Cluster Config Path: $KUBECONFIG"
echo "BMC Path: $bmc_path"
echo "------------------------"
echo "Proceeding with installation..."
echo "------------------------"

# Continue with installation
"$SCRIPT_DIR/scripts/install-dependents.sh"
helm uninstall traefik traefik-crd -n kube-system || true

# Add a small delay to ensure the CRDs are removed
sleep 5

helmfile apply -l name="metallb"
helmfile apply -l name="cert-manager"
helmfile apply
helmfile sync # this is a bad thing to do

# Apply the configurable proxy chart
"$SCRIPT_DIR/scripts/apply-proxy.sh"

echo "------------------------"
echo "Installation complete!"
echo "Your panel should be accessible at: https://$panel_domain"
echo "Your Kubernetes dashboard should be accessible at: https://$k8s_dashboard_domain"
echo "Your invite code is: $invite_code"
echo "Please save this invite code for future reference."