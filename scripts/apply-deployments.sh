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
NON_PERSISTENT_VALUES_DIR="${SCRIPT_DIR}/../local/deployments/non-persistent"
PERSISTENT_VALUES_DIR="${SCRIPT_DIR}/../local/deployments/persistent"
NON_PERSISTENT_CHART_DIR="${SCRIPT_DIR}/../charts/non-persistent-deployment-chart"
PERSISTENT_CHART_DIR="${SCRIPT_DIR}/../charts/persistent-deployment-chart"

# Function to process and deploy deployments
deploy_deployments() {
    local values_dir="$1"
    local chart_dir="$2"
    local deployment_type="$3"

    # Get a list of currently deployed deployments for this type
    DEPLOYED_DEPLOYMENTS=$(kubectl get deployments -n default -o jsonpath="{.items[?(@.spec.template.metadata.labels.kyriji\\.dev/deployment-type==\"$deployment_type\")].metadata.name}")

    # Get a list of deployment files (without extension and with 'disabled-' prefix removed)
    AVAILABLE_DEPLOYMENTS=$(find "${values_dir}" -type f \( -name "*.yaml" -o -name "*.yml" \) | xargs -n1 basename | sed -e 's/\.[^.]*$//' -e 's/^disabled-//')

    # Loop through deployed deployments and delete any that no longer have a corresponding values file
    for deployment in $DEPLOYED_DEPLOYMENTS; do
        if ! echo "$AVAILABLE_DEPLOYMENTS" | grep -q "^$deployment$"; then
            echo "Deleting removed $deployment_type deployment: $deployment"
            helm uninstall "$deployment" --namespace default
        fi
    done

    # Process both .yaml and .yml files
    for values_file in "${values_dir}"/*.{yaml,yml}; do
        [ -f "$values_file" ] || continue  # Skip if no matches

        # Extract the deployment name from the filename and remove 'disabled-' prefix if present
        original_deployment=$(basename "$values_file" .${values_file##*.})
        deployment=${original_deployment#disabled-}

        # Skip processing if the original filename started with 'disabled-'
        if [[ "$original_deployment" == disabled-* ]]; then
            echo "Skipping disabled deployment: $deployment"
            continue
        fi

        echo "Processing $deployment_type deployment: $deployment"

        # Debug: Show the values that will be used
        echo "Values file contents:"
        cat "$values_file"

        # Deploy using Helm
        echo "Deploying $deployment..."
        helm upgrade --install "$deployment" "${chart_dir}" \
            --values "$values_file" \
            --namespace default \
            --set "deployment.type=$deployment_type" \
            --debug \
            --dry-run  # First do a dry run to see what would be created

        # If dry run succeeds, do the actual deployment
        helm upgrade --install "$deployment" "${chart_dir}" \
            --values "$values_file" \
            --namespace default \
            --set "deployment.type=$deployment_type"

        # Verify deployment
        echo "Verifying $deployment_type deployment..."
        kubectl get deployment "$deployment" -n default -o yaml
    done
}

# Deploy non-persistent deployments
echo "Deploying Non-Persistent Deployments:"
deploy_deployments "$NON_PERSISTENT_VALUES_DIR" "$NON_PERSISTENT_CHART_DIR" "non-persistent"

# Deploy persistent deployments
echo "Deploying Persistent Deployments:"
deploy_deployments "$PERSISTENT_VALUES_DIR" "$PERSISTENT_CHART_DIR" "persistent"

# Show final state
echo "Final Helm releases:"
AVAILABLE_DEPLOYMENTS
echo "Final Kubernetes deployments:"
kubectl get deployments -n default -o wide

echo "Deployment of all deployments completed successfully."