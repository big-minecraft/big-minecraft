#!/bin/sh
set -eu

mc alias set store "$ARTIFACT_ENDPOINT" "$ARTIFACT_ACCESS_KEY" "$ARTIFACT_SECRET_KEY"

echo "Publishing ${DEPLOYMENT_NAME} ${VERSION}..."

DEST="store/${ARTIFACT_BUCKET}/deployments/${DEPLOYMENT_NAME}/${VERSION}/"
mc mirror --overwrite --exclude 'lost+found/*' "$MOUNT_PATH" "$DEST"

if [ -z "$(mc ls "$DEST" 2>/dev/null)" ]; then
  echo "Nothing to publish: ${MOUNT_PATH} holds no deployment files"
  exit 1
fi

echo "Published ${VERSION}"