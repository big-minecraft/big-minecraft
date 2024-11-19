#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

set -e  # Exit on error
set -x  # Enable debug output

# Get the directory where the script is located, resolving symlinks
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if Helm is installed
if ! command_exists helm; then
    echo "Helm is not installed. Please install it by following the instructions at https://helm.sh/docs/intro/install/"
    exit 1
fi

# Check if Helmfile is installed
if ! command_exists helmfile; then
    echo "Helmfile is not installed. Please install it by following the instructions at https://github.com/roboll/helmfile#installation"
    exit 1
fi

# Define the paths relative to the script location
VALUES_DIR="${SCRIPT_DIR}/../local/gamemodes"
CHART_DIR="${SCRIPT_DIR}/../charts/gamemodes-chart"

# Verify chart structure
if [ ! -d "${CHART_DIR}/templates" ]; then
    echo "Creating templates directory..."
    mkdir -p "${CHART_DIR}/templates"
fi

# Get a list of currently deployed Helm releases
DEPLOYED_GAMEMODES=$(helm list -q --namespace default)

# Get a list of gamemode files (without extension) in the values directory
AVAILABLE_GAMEMODES=$(find "${VALUES_DIR}" -type f -name "*.yaml" -o -name "*.yml" | xargs -n1 basename | sed 's/\.[^.]*$//')

# Loop through deployed gamemodes and delete any that no longer have a corresponding values file
for gamemode in $DEPLOYED_GAMEMODES; do
    # Check if the deployment has the required label
    if kubectl get deployment "$gamemode" -n default -o jsonpath='{.spec.template.metadata.labels.kyriji\.dev/enable-server-discovery}' | grep -q "true"; then
        if ! echo "$AVAILABLE_GAMEMODES" | grep -q "^$gamemode$"; then
            echo "Deleting removed gamemode: $gamemode"
            helm uninstall "$gamemode" --namespace default
        fi
    fi
done

# Process both .yaml and .yml files
for values_file in "${VALUES_DIR}"/*.{yaml,yml}; do
    [ -f "$values_file" ] || continue  # Skip if no matches

    # Extract the gamemode name from the filename
    gamemode=$(basename "$values_file" .${values_file##*.})
    echo "Processing gamemode: $gamemode"

    # Debug: Show the values that will be used
    echo "Values file contents:"
    cat "$values_file"

    # Deploy using Helm
    echo "Deploying $gamemode..."
    helm upgrade --install "$gamemode" "${CHART_DIR}" \
        --values "$values_file" \
        --namespace default \
        --debug \
        --dry-run  # First do a dry run to see what would be created

    # If dry run succeeds, do the actual deployment
    helm upgrade --install "$gamemode" "${CHART_DIR}" \
        --values "$values_file" \
        --namespace default

    # Verify deployment
    echo "Verifying deployment..."
    kubectl get deployment "$gamemode" -n default -o yaml
done

# Show final state
echo "Final Helm releases:"
helm list --namespace default

#helmfile apply --file "${SCRIPT_DIR}/../helmfile.yaml"

echo "Final Kubernetes deployments:"
kubectl get deployments -n default -o wide

echo "Deployment of all gamemodes completed successfully."
