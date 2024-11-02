#!/bin/bash
set -e  # Exit on error
set -x  # Enable debug output

# Get the directory where the script is located, resolving symlinks
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if required commands exist
if ! command_exists helm; then
    echo "Helm is not installed. Please install it by following the instructions at https://helm.sh/docs/intro/install/"
    exit 1
fi

if ! command_exists helmfile; then
    echo "Helmfile is not installed. Please install it by following the instructions at https://github.com/roboll/helmfile#installation"
    exit 1
fi

# Define the paths relative to the script location
VALUES_DIR="${SCRIPT_DIR}/../gamemodes"
CHART_DIR="${SCRIPT_DIR}/.."
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"

# Cleanup function
cleanup_resources() {
    echo "Cleaning up existing resources..."

    # Delete existing service accounts that might conflict
    kubectl delete serviceaccount velocity-account --namespace default --ignore-not-found

    # Clean up helmfile releases
    helmfile --file "${SCRIPT_DIR}/../helmfile.yaml" destroy

    # Delete any lingering resources
    kubectl delete deployment minecraft --namespace default --ignore-not-found
    kubectl delete service minecraft-service --namespace default --ignore-not-found

    # Clean up namespaces if empty
    for ns in default minecraft; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            if [ -z "$(kubectl get all -n "$ns" -o name 2>/dev/null)" ]; then
                kubectl delete namespace "$ns" --ignore-not-found
            fi
        fi
    done
}

# Run cleanup
cleanup_resources

# Create necessary directories
mkdir -p "${CHART_DIR}/templates"

# First, sync repositories
echo "Syncing helm repositories..."
helmfile --file "${SCRIPT_DIR}/../helmfile.yaml" repos

# Apply infrastructure components using helmfile
echo "Applying infrastructure components..."
helmfile --file "${SCRIPT_DIR}/../helmfile.yaml" sync

# Wait for cert-manager to be ready
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=300s || true
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=300s || true

# Apply ClusterIssuer
echo "Applying ClusterIssuer..."
kubectl apply -f "${MANIFESTS_DIR}/cluster-issuer.yaml"

# Get a list of currently deployed Helm releases
DEPLOYED_GAMEMODES=$(helm list -q -n minecraft)

# Get a list of gamemode files (without extension) in the values directory
AVAILABLE_GAMEMODES=$(find "${VALUES_DIR}" -type f -name "*.yaml" -o -name "*.yml" | xargs -n1 basename | sed 's/\.[^.]*$//')

# Loop through deployed gamemodes and delete any that no longer have a corresponding values file
for gamemode in $DEPLOYED_GAMEMODES; do
    if kubectl get deployment "$gamemode" -n minecraft -o jsonpath='{.spec.template.metadata.labels.kyriji\.dev/enable-server-discovery}' 2>/dev/null | grep -q "true"; then
        if ! echo "$AVAILABLE_GAMEMODES" | grep -q "^$gamemode$"; then
            echo "Deleting removed gamemode: $gamemode"
            helm uninstall "$gamemode" -n minecraft
        fi
    fi
done

# Process both .yaml and .yml files
for values_file in "${VALUES_DIR}"/*.{yaml,yml}; do
    [ -f "$values_file" ] || continue  # Skip if no matches

    # Extract the gamemode name from the filename
    gamemode=$(basename "$values_file" .${values_file##*.})
    echo "Processing gamemode: $gamemode"

    # Create namespace if it doesn't exist
    kubectl create namespace minecraft --dry-run=client -o yaml | kubectl apply -f -

    # Debug: Show the values that will be used
    echo "Values file contents:"
    cat "$values_file"

    # Do a dry-run first to validate the deployment
    if ! helm upgrade --install "$gamemode" "${CHART_DIR}" \
        --namespace minecraft \
        --values "$values_file" \
        --debug \
        --dry-run; then
        echo "Dry run failed for $gamemode, skipping deployment"
        continue
    fi

    # If dry run succeeds, do the actual deployment with force flag to ensure update
    echo "Deploying $gamemode..."
    helm upgrade --install "$gamemode" "${CHART_DIR}" \
        --namespace minecraft \
        --values "$values_file" \
        --force \
        --atomic \
        --timeout 5m

    # Wait for deployment to be ready
    echo "Waiting for deployment to be ready..."
    kubectl rollout status deployment/"$gamemode" -n minecraft --timeout=300s

    # Verify deployment
    echo "Verifying deployment..."
    kubectl get deployment "$gamemode" -n minecraft -o wide
done

# Show final state
echo "Final Helm releases:"
helm list --all-namespaces

echo "Final Kubernetes deployments:"
kubectl get deployments --all-namespaces -o wide

echo "Final Kubernetes services:"
kubectl get services --all-namespaces -o wide

echo "Deployment of all gamemodes completed successfully."