#!/bin/bash
# NFS Minecraft Volume Auto-Discovery via Pod/Daemonset IPs
# Configuration Variables
CONTROL_PLANE_BASE_MOUNT_DIR="/mnt/nfsshare"
NFS_POD_SELECTOR="app=nfs-server"
NAMESPACE="default"
NFS_EXPORT_PATH="/"  # Changed to root export path
MOUNT_OPTIONS="nolock,vers=4" # Simplified to match your working mount command
LOG_FILE="/var/log/minecraft-nfs-mounter.log"
INTERVAL=5  # Seconds between discovery/recovery cycles
# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}
# Function to discover NFS server pod IPs
discover_nfs_pods() {
    # Use -o go-template to explicitly handle multiple pods
    kubectl get pods -n "$NAMESPACE" -l "$NFS_POD_SELECTOR" \
        -o go-template='{{range .items}}{{.status.podIP}} {{end}}'
}
# Validate NFS server connectivity
validate_nfs_server() {
    local pod_ip=$1
    # Attempt to ping the IP as a basic connectivity check
    if ping -c 3 "$pod_ip" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}
# Mount NFS volume
mount_nfs_volume() {
    local pod_ip=$1
    local node_name=$2
    local mount_point="$CONTROL_PLANE_BASE_MOUNT_DIR/nodes/$node_name"
    # Create mount directory if not exists
    mkdir -p "$mount_point"
    # Attempt to mount using the working method
    if mount -t nfs -o "$MOUNT_OPTIONS" "$pod_ip:/" "$mount_point"; then
        log_message "Successfully mounted NFS from $pod_ip to $mount_point"
        return 0
    else
        log_message "FAILED to mount NFS from $pod_ip"
        return 1
    fi
}
# Cleanup function for stale mounts
cleanup_stale_mounts() {
    for mount_point in "$CONTROL_PLANE_BASE_MOUNT_DIR"/nodes; do
        if [[ -d "$mount_point" ]]; then
            if ! mountpoint -q "$mount_point" || ! timeout 3 touch "$mount_point" 2>/dev/null; then
                log_message "Cleaning up stale mount: $mount_point"
                umount -f "$mount_point" 2>/dev/null
                rmdir "$mount_point" 2>/dev/null
            fi
        fi
    done
}
# Main discovery and mounting loop
main_nfs_discovery() {
    while true; do
        cleanup_stale_mounts
        # Discover NFS pods
        nfs_pods=$(discover_nfs_pods)
        successful_mounts=0
        failed_mounts=0
        for pod_ip in $nfs_pods; do
            if validate_nfs_server "$pod_ip"; then
                if mount_nfs_volume "$pod_ip"; then
                    ((successful_mounts++))
                else
                    ((failed_mounts++))
                fi
            else
                log_message "NFS server not responsive on $pod_ip"
                ((failed_mounts++))
            fi
        done
        log_message "NFS Discovery Cycle Complete: $successful_mounts successful, $failed_mounts failed"
        sleep "$INTERVAL"
    done
}
# Error handling and signal traps
trap 'log_message "Script interrupted. Cleaning up..."; cleanup_stale_mounts; exit 1' SIGINT SIGTERM
# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   log_message "This script must be run as root"
   exit 1
fi
# Start the main discovery process
main_nfs_discovery