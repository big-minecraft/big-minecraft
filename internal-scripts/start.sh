#!/bin/bash

# Define the new directory to copy the files to
NEW_DIR="/usr/local/minecraft"

# Create the new directory if it doesn't exist
mkdir -p "$NEW_DIR"

# Copy all files from /mnt/local/minecraft to the new directory
cp -r /mnt/local/minecraft/* "$NEW_DIR"

# Change directory to the new folder
cd "$NEW_DIR"

# Start the Minecraft server from the new directory
exec java -jar server.jar --nogui
