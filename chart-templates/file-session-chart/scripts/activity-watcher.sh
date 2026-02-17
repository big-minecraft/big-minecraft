#!/bin/sh
set -e

apk add --no-cache inotify-tools curl >/dev/null 2>&1

echo 0 > /tmp/last_refresh

while true; do
  inotifywait -m -r -e modify,create,delete,move "$WATCH_PATH" 2>/dev/null |
  while read -r line; do
    NOW=$(date +%s)
    LAST=$(cat /tmp/last_refresh)
    if [ $((NOW - LAST)) -ge 30 ]; then
      echo "$NOW" > /tmp/last_refresh
      curl -sf -X POST "$PANEL_URL/api/files/session/internal-refresh" \
        -H "Content-Type: application/json" \
        -H "X-Service-Token: $SERVICE_TOKEN" \
        -d "{\"sessionId\":\"$SESSION_ID\"}" \
        >/dev/null 2>&1 || true
    fi
  done
  sleep 1
done