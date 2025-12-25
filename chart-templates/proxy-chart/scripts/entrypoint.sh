#!/usr/bin/env bash
set -e

if ! command -v redis-cli &> /dev/null; then
apt-get update &> /dev/null && apt-get install -y redis-tools &> /dev/null
fi

PLUGINS_DIR="{{ .Values.volume.mountPath | default "/minecraft" }}/plugins"
mkdir -p "$PLUGINS_DIR"
echo "Downloading bmc-velocity plugin..."
curl -L -o "$PLUGINS_DIR/bmc-velocity.jar" "https://github.com/big-minecraft/bmc-velocity/releases/latest/download/bmc-velocity.jar"
echo "Plugin downloaded successfully"

POD_LOCAL_DIR="/tmp/minecraft-server"
mkdir -p "$POD_LOCAL_DIR"

echo "Copying server files to pod-local directory..."
cp -r {{ .Values.volume.mountPath }}/* "$POD_LOCAL_DIR/"

cd "$POD_LOCAL_DIR"
if [ ! -f "./{{ .Values.server.jarName }}" ]; then
echo "Jar file not found! Check your deployment configuration file."
ls -la ./
exit 1
fi

send_redis_notification() {
local message="{\"server\": \"$HOSTNAME\", \"deployment\": \"$DEPLOYMENT_NAME\", \"event\": \"shutdown\", \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
redis-cli -h {{ .Values.server.redis.host }} -p {{ .Values.server.redis.port }} PUBLISH server-status "$message" &> /dev/null
echo "Sent shutdown notification to Redis"
}

SHUTDOWN_FLAG="/tmp/shutdown_in_progress"
rm -f $SHUTDOWN_FLAG

NOTIFICATION_SENT=0

handle_sigterm() {
if [ ! -f $SHUTDOWN_FLAG ]; then
echo "Received SIGTERM, shutting down Minecraft server gracefully..."
touch $SHUTDOWN_FLAG

echo "stop" >> /tmp/server_input

if [ $NOTIFICATION_SENT -eq 0 ]; then
  send_redis_notification
  NOTIFICATION_SENT=1
fi
fi
}

trap handle_sigterm SIGTERM

touch /tmp/should_run

rm -f /tmp/server_input
mkfifo /tmp/server_input

(while true; do sleep 3600; done) > /tmp/server_input &
PIPE_KEEPER_PID=$!

while [ ! -f $SHUTDOWN_FLAG ]; do
if [ -f /tmp/should_run ]; then
echo "Starting Minecraft server..."

java {{ .Values.server.jvmOpts | default "" }} -jar ./{{ .Values.server.jarName }} {{ .Values.server.args | default "nogui" }} < /tmp/server_input &
SERVER_PID=$!

while kill -0 $SERVER_PID 2>/dev/null && [ ! -f $SHUTDOWN_FLAG ]; do
  sleep 1
done

if [ -f $SHUTDOWN_FLAG ] && kill -0 $SERVER_PID 2>/dev/null; then
  echo "Ensuring server receives stop command..."
  echo "stop" >> /tmp/server_input

  timeout=30
  while [ $timeout -gt 0 ] && kill -0 $SERVER_PID 2>/dev/null; do
    sleep 1
    timeout=$((timeout-1))
  done

  if kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server didn't stop gracefully, force killing process..."
    kill -9 $SERVER_PID 2>/dev/null || true
  fi
fi

if [ $NOTIFICATION_SENT -eq 0 ]; then
  send_redis_notification
  NOTIFICATION_SENT=1
fi

if [ ! -f $SHUTDOWN_FLAG ]; then
  echo "Server stopped normally."
  NOTIFICATION_SENT=0

else
  echo "Shutdown flag detected, exiting server loop..."
  break
fi

sleep 1
else
sleep 5
fi
done

echo "Cleanup and exit..."
kill $PIPE_KEEPER_PID 2>/dev/null || true
exit 0