#!/bin/bash
# Configuration Variables
CONTROL_PLANE_BASE_MOUNT_DIR="/mnt/nfsshare/nodes"
NFS_POD_SELECTOR="app=nfs-server"
NAMESPACE="default"
NFS_EXPORT_PATH="/"  # Changed to root export path
MOUNT_OPTIONS="nolock,vers=4"
LOG_FILE="/var/log/minecraft-nfs-mounter.log"
INTERVAL=5  # Seconds between discovery/recovery cycles
# Keep track of already mounted IPs
declare -A mounted_ips
# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}
# Discover NFS server pod IPs
discover_nfs_pods() {
    kubectl get pods -n "$NAMESPACE" -l "$NFS_POD_SELECTOR" \
        -o go-template='{{range .items}}{{.status.podIP}} {{end}}'
}
# Check if IP is a master node
is_master_node() {
    local pod_ip=$1
    log_message "DEBUG: Checking if $pod_ip is a master node"

    # Get all master node IPs
    local master_ips=$(kubectl get nodes -l node-role.kubernetes.io/master="" -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')

    log_message "DEBUG: Master node IPs found: $master_ips"

    # Check if the pod IP matches any master node IP
    for master_ip in $master_ips; do
        log_message "DEBUG: Comparing $pod_ip with master IP $master_ip"
        if [[ "$pod_ip" == "$master_ip" ]]; then
            log_message "DEBUG: $pod_ip is a MASTER NODE"
            return 0  # Is a master node
        fi
    done

    log_message "DEBUG: $pod_ip is NOT a master node"
    return 1  # Not a master node
}
# Validate NFS server connectivity
validate_nfs_server() {
    local pod_ip=$1
    if ping -c 3 "$pod_ip" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}
# Mount NFS volume
mount_nfs_volume() {
    local pod_ip=$1
    local mount_point="$CONTROL_PLANE_BASE_MOUNT_DIR/$pod_ip"
    # Check if already mounted
    if grep -q "$mount_point" /proc/mounts; then
        log_message "NFS server $pod_ip is already mounted at $mount_point"
        return 0
    fi
    # Create mount directory if not exists
    mkdir -p "$mount_point"
    # Attempt to mount
    if mount -t nfs -o "$MOUNT_OPTIONS" "$pod_ip:$NFS_EXPORT_PATH" "$mount_point"; then
        log_message "Successfully mounted NFS from $pod_ip to $mount_point"
        mounted_ips["$pod_ip"]=1
        return 0
    else
        log_message "FAILED to mount NFS from $pod_ip"
        return 1
    fi
}
# Cleanup function for stale mounts
cleanup_stale_mounts() {
    for pod_ip in "${!mounted_ips[@]}"; do
        local mount_point="$CONTROL_PLANE_BASE_MOUNT_DIR/$pod_ip"
        if ! mountpoint -q "$mount_point" || ! timeout 3 touch "$mount_point" 2>/dev/null; then
            log_message "Cleaning up stale mount: $mount_point"
            umount -f "$mount_point" 2>/dev/null
            rmdir "$mount_point" 2>/dev/null
            unset mounted_ips["$pod_ip"]
        fi
    done
}
# Cleanup unused mount directories
cleanup_unused_mount_directories() {
    for mount_point in $(find "$CONTROL_PLANE_BASE_MOUNT_DIR" -mindepth 1 -type d); do
        if ! grep -q "$mount_point" /proc/mounts; then
            log_message "Removing unused directory: $mount_point"
            rmdir "$mount_point" 2>/dev/null || log_message "Failed to remove directory $mount_point"
        fi
    done
}
# Main discovery and mounting loop
main_nfs_discovery() {
    while true; do
        nfs_pods=$(discover_nfs_pods)
        log_message "DEBUG: Discovered NFS pods: $nfs_pods"

        successful_mounts=0
        failed_mounts=0
        for pod_ip in $nfs_pods; do
            # Skip master nodes
            if is_master_node "$pod_ip"; then
                log_message "SKIPPING master node IP: $pod_ip"
                continue
            fi

            if [[ -n "${mounted_ips[$pod_ip]}" ]]; then
                log_message "Skipping already mounted NFS server: $pod_ip"
                continue
            fi
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
        # Cleanup stale and unused mounts only if discovery/mounting didn't fail
        if [[ $failed_mounts -eq 0 ]]; then
            cleanup_stale_mounts
            cleanup_unused_mount_directories
        fi
    done
}
# Signal traps
trap 'log_message "Script interrupted. Cleaning up..."; cleanup_stale_mounts; cleanup_unused_mount_directories; exit 1' SIGINT SIGTERM
# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    log_message "This script must be run as root"
    exit 1
fi
# Start the main discovery process
main_nfs_discovery