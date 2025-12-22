#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

command_exists() {
    command -v "$1" &>/dev/null
}

if ! command_exists helm || ! command_exists kubectl || ! command_exists jq; then
    echo "Missing required dependency (helm, kubectl, or jq)"
    exit 1
fi

force_purge_release() {
    local release="$1"
    helm uninstall "$release" -n default --wait --timeout 60s &>/dev/null || true
    helm delete "$release" -n default &>/dev/null || true
}

build_global_values() {
    local tmp
    tmp=$(mktemp)
    echo "global:" > "$tmp"
    if [ -f "${SCRIPT_DIR}/../values.yaml" ]; then
        sed 's/^/  /' "${SCRIPT_DIR}/../values.yaml" >> "$tmp"
    fi
    echo "$tmp"
}

deploy_resources() {
    local values_dir="$1"
    local chart_dir="$2"
    local deployment_type="$3"

    [ -d "$values_dir" ] || return 0

    echo "--- Category: $deployment_type ---"

    AVAILABLE_RELEASES=""
    for f in "${values_dir}"/*.{yaml,yml}; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        name="${name%.*}"
        name="${name#disabled-}"
        AVAILABLE_RELEASES="$AVAILABLE_RELEASES $name"
    done

    RAW_DATA=$(kubectl get deployments,statefulsets -n default -o json)

    DEPLOYS_TO_CHECK=$(echo "$RAW_DATA" | jq -r "
        .items[]
        | select(.spec.template.metadata.labels[\"kyriji.dev/deployment-type\"] == \"$deployment_type\")
        | .metadata.annotations[\"meta.helm.sh/release-name\"]
    " | sort -u)

    for release in $DEPLOYS_TO_CHECK; do
        [ "$release" = "null" ] && continue

        found=false
        for available in $AVAILABLE_RELEASES; do
            [ "$release" = "$available" ] && found=true
        done

        disabled=false
        if [[ -f "${values_dir}/disabled-${release}.yaml" || -f "${values_dir}/disabled-${release}.yml" ]]; then
            disabled=true
        fi

        if [ "$found" = false ] || [ "$disabled" = true ]; then
            force_purge_release "$release"
        fi
    done

    for values_file in "${values_dir}"/*.{yaml,yml}; do
        [ -f "$values_file" ] || continue
        filename="$(basename "$values_file")"
        [[ "$filename" == disabled-* ]] && continue

        release_name="${filename%.*}"

        STATUS=$(helm status "$release_name" -n default --output json 2>/dev/null | jq -r '.info.status' || echo "missing")

        TEMP_VALUES=$(build_global_values)

        if [ "$STATUS" != "deployed" ]; then
            force_purge_release "$release_name"
            helm install "$release_name" "$chart_dir" \
                --namespace default \
                --values "$values_file" \
                --values "$TEMP_VALUES" \
                --set "deployment.type=$deployment_type" \
                --set "podLabels.kyriji\.dev/deployment-type=$deployment_type"
        else
            helm upgrade "$release_name" "$chart_dir" \
                --namespace default \
                --values "$values_file" \
                --values "$TEMP_VALUES" \
                --set "deployment.type=$deployment_type" \
                --set "podLabels.kyriji\.dev/deployment-type=$deployment_type"
        fi

        rm -f "$TEMP_VALUES"
    done
}

MANIFEST_ROOT="${SCRIPT_DIR}/../manifests"
CHART_ROOT="${SCRIPT_DIR}/../chart-templates"

deploy_resources "${MANIFEST_ROOT}/persistent" "${CHART_ROOT}/persistent-deployment-chart" "persistent"
deploy_resources "${MANIFEST_ROOT}/scalable"   "${CHART_ROOT}/scalable-deployment-chart"   "scalable"
deploy_resources "${MANIFEST_ROOT}/proxy"      "${CHART_ROOT}/proxy-chart"                 "proxy"
deploy_resources "${MANIFEST_ROOT}/process"    "${CHART_ROOT}/process-chart"               "process"
