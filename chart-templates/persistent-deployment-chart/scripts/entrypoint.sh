#!/usr/bin/env bash
set -e

# Install redis-cli if it's not already installed
if ! command -v redis-cli &> /dev/null; then
  apt-get update &> /dev/null && apt-get install -y redis-tools &> /dev/null
fi

cd {{ .Values.volume.mountPath }}
if [ ! -f "./{{ .Values.server.jarName }}" ]; then
  echo "Jar file not found! Check your deployment configuration file."
  ls -la ./
  exit 1
fi

# Function to send Redis notification
send_redis_notification() {
  local message="{\"server\": \"$HOSTNAME\", \"deployment\": \"$DEPLOYMENT_NAME\", \"event\": \"shutdown\", \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
  redis-cli -h {{ .Values.server.redis.host }} -p {{ .Values.server.redis.port }} PUBLISH server-status "$message" &> /dev/null
  echo "Sent shutdown notification to Redis"
}

# Create a flag file to indicate if shutdown is in progress
SHUTDOWN_FLAG="/tmp/shutdown_in_progress"
rm -f $SHUTDOWN_FLAG

# Variable to track if notification was already sent
NOTIFICATION_SENT=0

# SIGTERM handler for graceful shutdown
handle_sigterm() {
  if [ ! -f $SHUTDOWN_FLAG ]; then
    echo "Received SIGTERM, shutting down Minecraft server gracefully..."
    # Create shutdown flag
    touch $SHUTDOWN_FLAG

    # Send stop command to Minecraft server
    echo "stop" >> /tmp/server_input

    # Notify Redis about shutdown - only once
    if [ $NOTIFICATION_SENT -eq 0 ]; then
      send_redis_notification
      NOTIFICATION_SENT=1
    fi
  fi
  # Don't exit the script - let the server shutdown naturally
}

# Set up the trap for SIGTERM
trap handle_sigterm SIGTERM

# Create control file - server should run when this exists
touch /tmp/should_run

# Setup the command pipe properly
rm -f /tmp/server_input
mkfifo /tmp/server_input

# Start a background process to keep the pipe open
# This prevents EOF when no commands are being sent
(while true; do sleep 3600; done) > /tmp/server_input &
PIPE_KEEPER_PID=$!

while [ ! -f $SHUTDOWN_FLAG ]; do
  if [ -f /tmp/should_run ]; then
    echo "Starting Minecraft server..."

    # Use tee to fork the input - so commands from the pipe can be processed
    # continuously while the script still runs
    java {{ .Values.server.jvmOpts | default "" }} -jar ./{{ .Values.server.jarName }} {{ .Values.server.args | default "nogui" }} < /tmp/server_input &
    SERVER_PID=$!

    # Wait until either the server stops or a shutdown signal was received
    while kill -0 $SERVER_PID 2>/dev/null && [ ! -f $SHUTDOWN_FLAG ]; do
      sleep 1
    done

    # If shutdown flag exists but server is still running, explicitly send stop command
    if [ -f $SHUTDOWN_FLAG ] && kill -0 $SERVER_PID 2>/dev/null; then
      echo "Ensuring server receives stop command..."
      echo "stop" >> /tmp/server_input

      # Wait for server to stop with a reasonable timeout
      timeout=30
      while [ $timeout -gt 0 ] && kill -0 $SERVER_PID 2>/dev/null; do
        sleep 1
        timeout=$((timeout-1))
      done

      # Force kill if necessary
      if kill -0 $SERVER_PID 2>/dev/null; then
        echo "Server didn't stop gracefully, force killing process..."
        kill -9 $SERVER_PID 2>/dev/null || true
      fi
    fi

    # Clean up
    rm -f /tmp/should_run

    # If shutdown was not requested but server stopped normally,
    # send notification only if one wasn't sent already
    if [ ! -f $SHUTDOWN_FLAG ] && [ $NOTIFICATION_SENT -eq 0 ]; then
      send_redis_notification
      NOTIFICATION_SENT=1
    fi

    # ---- FIX: Reset state for next restart cycle if not shutting down ----
    if [ ! -f $SHUTDOWN_FLAG ]; then
      # Server stopped without shutdown flag, it's a normal restart
      echo "Server stopped normally, preparing for restart..."
      # Reset notification flag for next cycle
      NOTIFICATION_SENT=0
      # Ensure the should_run file exists for the next cycle
      touch /tmp/should_run
    else
      echo "Shutdown flag detected, exiting server loop..."
      break
    fi
    # ---- End of fix ----

    sleep 1
  else
    # Server should not be running, wait and check again
    sleep 5
  fi
done

echo "Cleanup and exit..."
# Kill the pipe keeper process
kill $PIPE_KEEPER_PID 2>/dev/null || true
exit 0