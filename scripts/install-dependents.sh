#!/bin/bash

set -e

# Version constants
CURL_VERSION="v8.10.1"
HELM_VERSION="v3.16.2"
HELMFILE_VERSION="v0.158.0"
HELM_DIFF_VERSION="v3.9.11"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

echo "Starting installation of helm tools"

# Install curl if not present
if ! command_exists curl; then
    echo "Installing curl"
    wget -q "https://github.com/moparisthebest/static-curl/releases/download/${CURL_VERSION}/curl-amd64" -O /usr/local/bin/curl
    chmod +x /usr/local/bin/curl
    export PATH="/usr/local/bin:$PATH"
fi

# Install helm if not present
if ! command_exists helm; then
    echo "Installing helm"
    curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz
    mv linux-amd64/helm /usr/local/bin/
    rm -rf linux-amd64
fi

# Install helmfile if not present
if ! command_exists helmfile; then
    echo "Installing helmfile"
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    curl -sL "https://github.com/helmfile/helmfile/releases/download/${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION#v}_linux_amd64.tar.gz" | tar xz
    chmod +x helmfile
    mv helmfile /usr/local/bin/
    cd - > /dev/null
    rm -rf "$TMP_DIR"
fi

# Install helm-diff plugin if not present
if ! helm plugin list | grep -q "diff"; then
    echo "Installing helm-diff plugin"
    PLUGIN_DIR="${HELM_PLUGIN_DIR:-$HOME/.local/share/helm/plugins}"
    mkdir -p "$PLUGIN_DIR"
    curl -sL "https://github.com/databus23/helm-diff/releases/download/${HELM_DIFF_VERSION}/helm-diff-linux-amd64.tgz" | tar xz -C "$PLUGIN_DIR"
fi

# Verify installations
echo -e "\nVerifying installations:"
echo "Helm: $(helm version --short)"
echo "Helmfile: $(helmfile -v)"
echo "Helm-diff: $(helm plugin list | grep diff)"

echo "Installation complete!"