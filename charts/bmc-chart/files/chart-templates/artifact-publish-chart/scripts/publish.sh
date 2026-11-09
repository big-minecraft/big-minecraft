#!/bin/sh
set -eu

mc alias set store "$ARTIFACT_ENDPOINT" "$ARTIFACT_ACCESS_KEY" "$ARTIFACT_SECRET_KEY"

echo "Publishing ${DEPLOYMENT_NAME} ${VERSION}..."

DEST="store/${ARTIFACT_BUCKET}/deployments/${DEPLOYMENT_NAME}/${VERSION}/"
mc mirror --overwrite --exclude 'lost+found/*' "$MOUNT_PATH" "$DEST"

# Exit codes are a contract with the panel:
#   0  published -- the version exists in the store and is safe to record
#   3  nothing to publish -- the volume holds no deployment files
#   *  the publish itself failed (mc error, credentials, network) 
if [ -z "$(mc ls "$DEST" 2>/dev/null)" ]; then
  echo "Nothing to publish: ${MOUNT_PATH} holds no deployment files"
  exit 3
fi

echo "Published ${VERSION}"
