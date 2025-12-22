#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

if ! command_exists helm; then
    echo "Error: Helm is not installed."
    exit 1
fi

# Function to process and deploy deployments
deploy_deployments() {
    local values_dir="$1"
    local chart_dir="$2"
    local deployment_type="$3"

    if [ ! -d "$values_dir" ]; then
        echo "Warning: Values directory $values_dir does not exist. Skipping."
        return 0
    fi

    echo "--- Category: $deployment_type ---"

    # 1. Get Local Names (Current configurations)
    AVAILABLE_RELEASES=""
    for f in "${values_dir}"/*.{yaml,yml}; do
        [ -e "$f" ] || continue
        fname=$(basename "$f")
        name="${fname%.*}"
        name="${name#disabled-}"
        AVAILABLE_RELEASES="$AVAILABLE_RELEASES $name"
    done

    # 2. Cleanup Phase
    # We query for all Deployments and StatefulSets.
    # We use a custom jsonpath to extract the Release Name from Annotations if labels are missing.
    # We also check the Pod Template labels for your deployment-type.

    RAW_DATA=$(kubectl get deployments,statefulsets -n default -o json)

    # Use python or a simple loop to parse the JSON for orphans
    # This finds resources where:
    # (Label kyriji.dev/deployment-type == category) AND (Release Name NOT in AVAILABLE_RELEASES)

    DEPLOYS_TO_CHECK=$(echo "$RAW_DATA" | jq -r ".items[] |
        select(.spec.template.metadata.labels[\"kyriji.dev/deployment-type\"] == \"$deployment_type\") |
        .metadata.annotations[\"meta.helm.sh/release-name\"]" 2>/dev/null | sort | uniq)

    for release in $DEPLOYS_TO_CHECK; do
        [ "$release" == "null" ] && continue

        found=false
        for available in $AVAILABLE_RELEASES; do
            if [ "$release" = "$available" ]; then
                found=true
                break
            fi
        done

        # If it's on the cluster but not in the folder (or marked as disabled)
        is_disabled=false
        if [[ -f "${values_dir}/disabled-${release}.yaml" || -f "${values_dir}/disabled-${release}.yml" ]]; then
            is_disabled=true
        fi

        if [ "$found" = false ] || [ "$is_disabled" = true ]; then
            echo "Removing orphaned or disabled release: $release"
            helm uninstall "$release" --namespace default --wait
        fi
    done

    # 3. Deployment Phase
    for values_file in "${values_dir}"/*.{yaml,yml}; do
        [ -f "$values_file" ] || continue
        filename=$(basename "$values_file")
        [[ "$filename" == disabled-* ]] && continue

        # Create temporary values file with global config
        TEMP_VALUES=$(mktemp)
        echo "global:" > "$TEMP_VALUES"
        sed 's/^/  /' "${SCRIPT_DIR}/../local/global-config.yaml" >> "$TEMP_VALUES"

        # Deploy using Helm
        echo "Deploying $deployment..."
        helm upgrade --install "$deployment" "${chart_dir}" \
            --values "$values_file" \
            --values "$TEMP_VALUES" \
            --namespace default \
            --set "deployment.type=$deployment_type" \
            --set "podLabels.kyriji\.dev/deployment-type=$deployment_type"

        # If dry run succeeds, do the actual deployment
        if helm upgrade --install "$deployment" "${chart_dir}" \
            --values "$values_file" \
            --values "$TEMP_VALUES" \
            --namespace default \
            --set "deployment.type=$deployment_type"; then
            echo "Successfully deployed $deployment"
        else
            echo "Failed to deploy $deployment"
            rm -f "$TEMP_VALUES"
            exit 1
        fi

        # Clean up temporary file
        rm -f "$TEMP_VALUES"

        # Verify deployment
        echo "Verifying $deployment_type deployment..."
        kubectl get deployment "$deployment" -n default -o yaml
    done
}

# --- Execution ---
# Note: I added a check for 'jq' which is much better at parsing the complex K8s metadata
if ! command_exists jq; then
    echo "This script requires 'jq'. Please install it (apt-get install jq / brew install jq)."
    exit 1
fi

MANIFEST_ROOT="${SCRIPT_DIR}/../manifests"
CHART_ROOT="${SCRIPT_DIR}/../chart-templates"

deploy_resources "${MANIFEST_ROOT}/persistent" "${CHART_ROOT}/persistent-deployment-chart" "persistent"
deploy_resources "${MANIFEST_ROOT}/scalable"   "${CHART_ROOT}/scalable-deployment-chart"   "scalable"
deploy_resources "${MANIFEST_ROOT}/proxy"      "${CHART_ROOT}/proxy-chart"                 "proxy"
deploy_resources "${MANIFEST_ROOT}/process"    "${CHART_ROOT}/process-chart"               "process"