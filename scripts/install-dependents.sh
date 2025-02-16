#!/bin/bash
set -e

# Version constants
CURL_VERSION="v8.10.1"
HELM_VERSION="v3.16.2"
HELMFILE_VERSION="v0.158.0"
HELM_DIFF_VERSION="v3.9.11"
KUBECTL_VERSION="v1.29.2"
NFS_UTILS_VERSION="2.6.4"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

echo "Starting installation of dependencies"

# Install curl
if ! command_exists curl; then
    wget "https://github.com/moparisthebest/static-curl/releases/download/${CURL_VERSION}/curl-amd64" -O /usr/local/bin/curl
    chmod +x /usr/local/bin/curl
    export PATH="/usr/local/bin:$PATH"
fi

# Install kubectl
if ! command_exists kubectl; then
    echo "Installing kubectl"
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
fi

# Install helm
if ! command_exists helm; then
    echo "Installing helm"
    curl -L "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz
    mv linux-amd64/helm /usr/local/bin/
    rm -rf linux-amd64
fi

# Install helmfile
if ! command_exists helmfile; then
    echo "Installing helmfile"
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    curl -L "https://github.com/helmfile/helmfile/releases/download/${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION#v}_linux_amd64.tar.gz" | tar xz
    chmod +x helmfile
    mv helmfile /usr/local/bin/
    cd - > /dev/null
    rm -rf "$TMP_DIR"
fi

# Install helm-diff
if ! helm plugin list | grep -q "diff"; then
    echo "Installing helm-diff plugin"
    PLUGIN_DIR="${HELM_PLUGIN_DIR:-$HOME/.local/share/helm/plugins}"
    mkdir -p "$PLUGIN_DIR"
    curl -L "https://github.com/databus23/helm-diff/releases/download/${HELM_DIFF_VERSION}/helm-diff-linux-amd64.tgz" | tar xz -C "$PLUGIN_DIR"
fi

# Install kubectl-node_shell
if ! command_exists kubectl-node_shell; then
    echo "Installing kubectl-node_shell"
    curl -LO https://github.com/kvaps/kubectl-node-shell/raw/master/kubectl-node_shell
    chmod +x ./kubectl-node_shell
    mv ./kubectl-node_shell /usr/local/bin/kubectl-node_shell
fi

# Install NFS common
if ! command_exists mount.nfs; then
    echo "Installing NFS common"
    if command_exists apt-get; then
        apt-get update && apt-get install -y nfs-common || true
    else
        echo "warning: apt not found, skipping nfs-common installation"
    fi
fi

# Verify installations
echo -e "\nVerifying installations:"
echo "Kubectl: $(kubectl version --client | grep 'Client Version:' | cut -d' ' -f3)"
echo "Helm: $(helm version --short)"
echo "Helmfile: $(helmfile -v)"
echo "Helm-diff: $(helm plugin list | grep diff)"
echo "kubectl-node_shell: $(command -v kubectl-node_shell || echo 'Not Found')"
echo "NFS Utils: $(
    apt list --installed 2>/dev/null | grep -q "nfs-common" &&
    apt list --installed 2>/dev/null | grep "nfs-common" | cut -d'/' -f1 ||
    echo "Not Found"
)"
echo "Installation complete!"