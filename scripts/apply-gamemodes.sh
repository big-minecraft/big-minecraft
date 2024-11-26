#!/bin/bash

# Get the directory where the script is located, resolving symlinks
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# Read KUBECONFIG from global-config.yaml
CONFIG_FILE="${SCRIPT_DIR}/../local/global-config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: global-config.yaml not found at $CONFIG_FILE"
    exit 1
fi
# Extract clusterConfigPath from global-config.yaml
KUBECONFIG=$(grep "clusterConfigPath:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
if [ -z "$KUBECONFIG" ]; then
    echo "Error: clusterConfigPath not found in global-config.yaml"
    exit 1
fi
# Try original path first, then prepend /host-root if not found
if [ ! -f "$KUBECONFIG" ]; then
    HOST_ROOT_KUBECONFIG="/host-root${KUBECONFIG}"
    if [ ! -f "$HOST_ROOT_KUBECONFIG" ]; then
        echo "Error: Kubernetes config file not found at $KUBECONFIG or $HOST_ROOT_KUBECONFIG"
        exit 1
    fi
    # Use the host-root path for file access but remove prefix before export
    FINAL_KUBECONFIG="${KUBECONFIG}"  # Save the original path
    KUBECONFIG="$HOST_ROOT_KUBECONFIG"  # Use host-root path to check file
else
    FINAL_KUBECONFIG="${KUBECONFIG}"  # Use original path
fi

# Export the path without /host-root prefix
export KUBECONFIG="${FINAL_KUBECONFIG}"

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

# Get a list of currently deployed gamemodes
DEPLOYED_GAMEMODES=$(kubectl get deployments -n default -o jsonpath='{.items[?(@.spec.template.metadata.labels.kyriji\.dev/enable-server-discovery=="true")].metadata.name}')
# Get a list of gamemode files (without extension) in the values directory
AVAILABLE_GAMEMODES=$(find "${VALUES_DIR}" -type f -name "*.yaml" -o -name "*.yml" | xargs -n1 basename | sed 's/\.[^.]*$//')

# Loop through deployed gamemodes and delete any that no longer have a corresponding values file
for gamemode in $DEPLOYED_GAMEMODES; do
    if ! echo "$AVAILABLE_GAMEMODES" | grep -q "^$gamemode$"; then
        echo "Deleting removed gamemode: $gamemode"
        helm uninstall "$gamemode" --namespace default
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

echo "Final Kubernetes deployments:"
kubectl get deployments -n default -o wide

echo "Deployment of all gamemodes completed successfully."