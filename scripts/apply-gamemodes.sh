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
NON_PERSISTENT_VALUES_DIR="${SCRIPT_DIR}/../local/gamemodes/non-persistent"
PERSISTENT_VALUES_DIR="${SCRIPT_DIR}/../local/gamemodes/persistent"
NON_PERSISTENT_CHART_DIR="${SCRIPT_DIR}/../charts/non-persistent-gamemode-chart"
PERSISTENT_CHART_DIR="${SCRIPT_DIR}/../charts/persistent-gamemode-chart"

# Function to process and deploy gamemodes
deploy_gamemodes() {
    local values_dir="$1"
    local chart_dir="$2"
    local deployment_type="$3"

    # Get a list of currently deployed gamemodes for this type
    DEPLOYED_GAMEMODES=$(kubectl get deployments -n default -o jsonpath="{.items[?(@.spec.template.metadata.labels.kyriji\\.dev/gamemode-type==\"$deployment_type\")].metadata.name}")

    # Get a list of gamemode files (without extension) in the values directory
    AVAILABLE_GAMEMODES=$(find "${values_dir}" -type f \( -name "*.yaml" -o -name "*.yml" \) | xargs -n1 basename | sed 's/\.[^.]*$//')

    # Loop through deployed gamemodes and delete any that no longer have a corresponding values file
    for gamemode in $DEPLOYED_GAMEMODES; do
        if ! echo "$AVAILABLE_GAMEMODES" | grep -q "^$gamemode$"; then
            echo "Deleting removed $deployment_type gamemode: $gamemode"
            helm uninstall "$gamemode" --namespace default
        fi
    done

    # Process both .yaml and .yml files
    for values_file in "${values_dir}"/*.{yaml,yml}; do
        [ -f "$values_file" ] || continue  # Skip if no matches

        # Extract the gamemode name from the filename
        gamemode=$(basename "$values_file" .${values_file##*.})
        echo "Processing $deployment_type gamemode: $gamemode"

        # Debug: Show the values that will be used
        echo "Values file contents:"
        cat "$values_file"

        # Deploy using Helm
        echo "Deploying $gamemode..."
        helm upgrade --install "$gamemode" "${chart_dir}" \
            --values "$values_file" \
            --namespace default \
            --set "gamemode.type=$deployment_type" \
            --debug \
            --dry-run  # First do a dry run to see what would be created

        # If dry run succeeds, do the actual deployment
        helm upgrade --install "$gamemode" "${chart_dir}" \
            --values "$values_file" \
            --namespace default \
            --set "gamemode.type=$deployment_type"

        # Verify deployment
        echo "Verifying $deployment_type deployment..."
        kubectl get deployment "$gamemode" -n default -o yaml
    done
}

# Deploy non-persistent gamemodes
echo "Deploying Non-Persistent Gamemodes:"
deploy_gamemodes "$NON_PERSISTENT_VALUES_DIR" "$NON_PERSISTENT_CHART_DIR" "non-persistent"

# Deploy persistent gamemodes
echo "Deploying Persistent Gamemodes:"
deploy_gamemodes "$PERSISTENT_VALUES_DIR" "$PERSISTENT_CHART_DIR" "persistent"

# Show final state
echo "Final Helm releases:"
helm list --namespace default

echo "Final Kubernetes deployments:"
kubectl get deployments -n default -o wide

echo "Deployment of all gamemodes completed successfully."