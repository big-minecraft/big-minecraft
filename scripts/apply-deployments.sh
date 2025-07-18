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
KUBECONFIG=$(grep "^clusterConfigPath:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
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

# Function to process and deploy deployments
deploy_deployments() {
    local values_dir="$1"
    local chart_dir="$2"
    local deployment_type="$3"

    # Check if values directory exists
    if [ ! -d "$values_dir" ]; then
        echo "Warning: Values directory $values_dir does not exist. Skipping $deployment_type deployments."
        return 0
    fi

    # Get a list of currently deployed deployments for this type
    DEPLOYED_DEPLOYMENTS=$(kubectl get deployments -n default -o jsonpath="{.items[?(@.spec.template.metadata.labels.kyriji\\.dev/deployment-type==\"$deployment_type\")].metadata.name}" 2>/dev/null || echo "")

    # Get a list of deployment files more safely
    AVAILABLE_DEPLOYMENTS=""
    if find "${values_dir}" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null | grep -zq .; then
        AVAILABLE_DEPLOYMENTS=$(find "${values_dir}" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null | xargs -0 -n1 basename 2>/dev/null | sed -e 's/\.[^.]*$//' -e 's/^disabled-//' | sort | uniq)
    fi

    # Debug output
    echo "Available deployments in $values_dir:"
    if [ -n "$AVAILABLE_DEPLOYMENTS" ]; then
        echo "$AVAILABLE_DEPLOYMENTS"
    else
        echo "No deployment files found."
        return 0
    fi

    # Loop through deployed deployments and delete any that no longer have a corresponding values file
    if [ -n "$DEPLOYED_DEPLOYMENTS" ]; then
        for deployment in $DEPLOYED_DEPLOYMENTS; do
            if [ -n "$AVAILABLE_DEPLOYMENTS" ] && ! echo "$AVAILABLE_DEPLOYMENTS" | grep -q "^$deployment$"; then
                echo "Deleting removed $deployment_type deployment: $deployment"
                helm uninstall "$deployment" --namespace default
            fi
        done
    fi

    # Process both .yaml and .yml files
    for values_file in "${values_dir}"/*.{yaml,yml}; do
        [ -f "$values_file" ] || continue  # Skip if no matches

        # Extract the deployment name from the filename and remove 'disabled-' prefix if present
        original_deployment=$(basename "$values_file")
        # Remove file extension
        original_deployment="${original_deployment%.*}"
        deployment="${original_deployment#disabled-}"

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
            --set-file "global=${SCRIPT_DIR}/../local/global-config.yaml" \
            --namespace default \
            --set "deployment.type=$deployment_type" \
            --debug \
            --dry-run  # First do a dry run to see what would be created

        # If dry run succeeds, do the actual deployment
        if helm upgrade --install "$deployment" "${chart_dir}" \
            --values "$values_file" \
            --set-file "global=${SCRIPT_DIR}/../local/global-config.yaml" \
            --namespace default \
            --set "deployment.type=$deployment_type"; then
            echo "Successfully deployed $deployment"
        else
            echo "Failed to deploy $deployment"
            exit 1
        fi

        # Verify deployment
        echo "Verifying $deployment_type deployment..."
        kubectl get deployment "$deployment" -n default -o yaml
    done
}

# Define the paths relative to the script location
PERSISTENT_CHART_DIR="${SCRIPT_DIR}/../charts/persistent-deployment-chart"
PERSISTENT_VALUES_DIR="${SCRIPT_DIR}/../local/deployments/persistent"
SCALABLE_CHART_DIR="${SCRIPT_DIR}/../charts/scalable-deployment-chart"
SCALABLE_VALUES_DIR="${SCRIPT_DIR}/../local/deployments/scalable"
PROXY_CHART_DIR="${SCRIPT_DIR}/../charts/proxy-chart"
PROXY_VALUES_DIR="${SCRIPT_DIR}/../local/deployments/proxy"
PROCESS_CHART_DIR="${SCRIPT_DIR}/../charts/process-chart"
PROCESS_VALUES_DIR="${SCRIPT_DIR}/../local/deployments/process"

# Deploy persistent deployments
echo "Deploying Persistent Deployments:"
deploy_deployments "$PERSISTENT_VALUES_DIR" "$PERSISTENT_CHART_DIR" "persistent"

# Deploy scalable deployments
echo "Deploying Scalable Deployments:"
deploy_deployments "$SCALABLE_VALUES_DIR" "$SCALABLE_CHART_DIR" "scalable"

# Deploy proxy deployment
echo "Deploying Proxy Deployment:"
deploy_deployments "$PROXY_VALUES_DIR" "$PROXY_CHART_DIR" "proxy"

# Deploy process deployments
echo "Deploying Process Deployments:"
deploy_deployments "$PROCESS_VALUES_DIR" "$PROCESS_CHART_DIR" "process"

# Show final state
echo "Final Helm releases:"
helm list -n default

echo "Final Kubernetes deployments:"
kubectl get deployments -n default -o wide

echo "Deployment of all deployments completed successfully."