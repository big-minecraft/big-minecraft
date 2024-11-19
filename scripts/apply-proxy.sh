#!/bin/bash

# Configuration - Change these values as needed
RELEASE_NAME="proxy"  # The name of your Helm release
NAMESPACE="default"   # The namespace to deploy to
VALUES_FILE="${SCRIPT_DIR}/../local/proxy.yaml"  # Path to your values file

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

# Define the chart directory path
CHART_DIR="${SCRIPT_DIR}/../charts/proxy-chart"

# Verify chart structure
if [ ! -d "${CHART_DIR}/templates" ]; then
    echo "Creating templates directory..."
    mkdir -p "${CHART_DIR}/templates"
fi

# Check if values file exists
if [ ! -f "${VALUES_FILE}" ]; then
    echo "Values file not found at ${VALUES_FILE}"
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