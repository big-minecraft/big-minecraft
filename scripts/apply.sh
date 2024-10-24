#!/bin/bash

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

# Check if Helmfile is installed
if ! command_exists helmfile; then
    echo "Helmfile is not installed. Please install it by following the instructions at https://github.com/roboll/helmfile#installation"
    exit 1
fi

# Define the paths
VALUES_DIR="../gamemodes"
CHART_DIR=".."

# Verify chart structure
if [ ! -d "$CHART_DIR/templates" ]; then
    echo "Creating templates directory..."
    mkdir -p "$CHART_DIR/templates"
fi

# Process both .yaml and .yml files
for values_file in "$VALUES_DIR"/*.{yaml,yml}; do
    [ -f "$values_file" ] || continue  # Skip if no matches

    # Extract the gamemode name from the filename
    gamemode=$(basename "$values_file" .${values_file##*.})
    echo "Processing gamemode: $gamemode"

    # Debug: Show the values that will be used
    echo "Values file contents:"
    cat "$values_file"

    # Deploy using Helm
    echo "Deploying $gamemode..."
    helm upgrade --install "$gamemode" "$CHART_DIR" \
        --values "$values_file" \
        --debug \
        --dry-run  # First do a dry run to see what would be created

    # If dry run succeeds, do the actual deployment
    helm upgrade --install "$gamemode" "$CHART_DIR" \
        --values "$values_file"

    # Verify deployment
    echo "Verifying deployment..."
    kubectl get deployment "$gamemode" -o yaml
done

# Show final state
echo "Final Helm releases:"
helm list

echo "Final Kubernetes deployments:"
kubectl get deployments -o wide

echo "Deployment of all gamemodes completed successfully."