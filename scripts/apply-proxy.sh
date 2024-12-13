#!/bin/bash

# Configuration - Change these values as needed
RELEASE_NAME="proxy"  # The name of your Helm release
NAMESPACE="default"   # The namespace to deploy to

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

# Define paths relative to script location
VALUES_FILE="${SCRIPT_DIR}/../local/proxy.yaml"  # Path to your values file
CHART_DIR="${SCRIPT_DIR}/../charts/proxy-chart"

set -e  # Exit on error
set -x  # Enable debug output

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if Helm is installed
if ! command_exists helm; then
    echo "Helm is not installed. Please install it by following the instructions at https://helm.sh/docs/intro/install/"
    exit 1
fi

# Verify chart structure
if [ ! -d "${CHART_DIR}/templates" ]; then
    echo "Creating templates directory..."
    mkdir -p "${CHART_DIR}/templates"
fi

# Check if values file exists
if [ ! -f "${VALUES_FILE}" ]; then
    echo "Values file not found at ${VALUES_FILE}"
    echo "Current directory: $(pwd)"
    echo "Script directory: ${SCRIPT_DIR}"
    ls -la "${SCRIPT_DIR}/../local/"
    exit 1
fi

# Deploy using Helm
echo "Deploying ${RELEASE_NAME}..."

# First do a dry run to see what would be created
helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
    --values "${VALUES_FILE}" \
    --namespace $NAMESPACE \
    --debug \
    --dry-run

# If dry run succeeds, do the actual deployment
helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
    --values "${VALUES_FILE}" \
    --namespace $NAMESPACE

# Verify deployment
echo "Verifying deployment..."
kubectl get deployment "${RELEASE_NAME}" -n $NAMESPACE -o yaml

# Show final state
echo "Final Helm releases:"
helm list --namespace $NAMESPACE
echo "Final Kubernetes deployments:"
kubectl get deployments -n $NAMESPACE -o wide
echo "Deployment completed successfully."