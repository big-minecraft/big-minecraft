#!/bin/bash

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEFAULTS_DIR="${SCRIPT_DIR}/../defaults"
LOCAL_DIR="${SCRIPT_DIR}/../local"

# List of files to copy (add or remove files as needed)
FILES_TO_COPY=(
    "global-config.yaml"
    "proxy.yaml"
    # Add more files here as needed
)

set -e  # Exit on error
set -x  # Enable debug output

# Create local directory if it doesn't exist
mkdir -p "${LOCAL_DIR}"

# Create deployments directory if it doesn't exist
mkdir -p "${LOCAL_DIR}/deployments"
mkdir -p "${LOCAL_DIR}/deployments/persistent"
mkdir -p "${LOCAL_DIR}/deployments/non-persistent"




# Copy specific files from defaults to local
echo "Copying selected files from ${DEFAULTS_DIR} to ${LOCAL_DIR}"
for file in "${FILES_TO_COPY[@]}"; do
    if [ -f "${DEFAULTS_DIR}/${file}" ]; then
        cp "${DEFAULTS_DIR}/${file}" "${LOCAL_DIR}/"
    else
        echo "Warning: ${file} not found in ${DEFAULTS_DIR}"
    fi
done

echo "Files copied successfully. Current contents of local directory:"
ls -la "${LOCAL_DIR}"