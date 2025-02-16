#!/bin/bash
./scripts/install-dependents.sh

# Configuration Variables
CONTROL_PLANE_BASE_MOUNT_DIR="/mnt/nfsshare/nodes"
NFS_POD_SELECTOR="app=nfs-server"
NAMESPACE="default"
NFS_EXPORT_PATH="/"  # Changed to root export path
MOUNT_OPTIONS="nolock,vers=4"
LOG_FILE="/var/log/minecraft-nfs-mounter.log"
INTERVAL=5  # Seconds between discovery/recovery cycles
declare -A mounted_ips

mkdir -p $CONTROL_PLANE_BASE_MOUNT_DIR

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

is_master_node() {
    local node_name=$1
    local master_nodes
    master_nodes=$(kubectl get nodes -l node-role.kubernetes.io/master="true" -o jsonpath='{.items[*].metadata.name}')
    for master_node in $master_nodes; do
        if [[ "$node_name" == "$master_node" ]]; then
            return 0
        fi
    done
    return 1
}

discover_nfs_pods() {
    kubectl get pods -n "$NAMESPACE" -l "$NFS_POD_SELECTOR" \
        -o go-template='{{range .items}}{{.spec.nodeName}}:{{.status.podIP}} {{end}}'
}

validate_nfs_server() {
    local pod_ip=$1
    if ping -c 3 "$pod_ip" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

check_stale_mount() {
    local mount_point=$1
    local master_node
    master_node=$(kubectl get nodes -l node-role.kubernetes.io/master="true" -o jsonpath='{.items[0].metadata.name}')

    # Try to access the mount point
    if ! kubectl node-shell "$master_node" -- timeout 10 ls "$mount_point" >/dev/null 2>&1; then
        log_message "Detected stale mount at $mount_point"
        return 0  # Mount is stale
    fi
    return 1  # Mount is good
}

unmount_nfs() {
    local mount_point=$1
    local master_node
    master_node=$(kubectl get nodes -l node-role.kubernetes.io/master="true" -o jsonpath='{.items[0].metadata.name}')

    log_message "Attempting to unmount $mount_point"
    kubectl node-shell "$master_node" -- umount -l "$mount_point"
    if [ $? -eq 0 ]; then
        log_message "Successfully unmounted $mount_point"
        return 0
    else
        log_message "Failed to unmount $mount_point"
        return 1    
    fi
}

mount_nfs_volume() {
    local pod_ip=$1
    local node_name=$2
    local mount_point="$CONTROL_PLANE_BASE_MOUNT_DIR/$node_name"
    local master_node
    master_node=$(kubectl get nodes -l node-role.kubernetes.io/master="true" -o jsonpath='{.items[0].metadata.name}')

    # Check if already mounted
    if kubectl node-shell "$master_node" -- grep -q "$mount_point" /proc/mounts; then
        # Check if mount is stale
        if check_stale_mount "$mount_point"; then
            log_message "Found stale mount at $mount_point - attempting to unmount"
            unmount_nfs "$mount_point"
            # Clear the mounted_ips entry for this IP
            unset mounted_ips["$pod_ip"]
        else
            log_message "NFS server $pod_ip is already mounted at $mount_point and is healthy"
            return 0
        fi
    fi

    # Create mount directory if not exists
    mkdir -p "$mount_point"

    # Attempt to mount from the master node
    kubectl node-shell "$master_node" -- mount -t nfs -o "$MOUNT_OPTIONS" "$pod_ip:$NFS_EXPORT_PATH" "$mount_point"
    if [ $? -eq 0 ]; then
        log_message "Successfully mounted NFS from $pod_ip (Node: $node_name) to $mount_point"
        mounted_ips["$pod_ip"]=1
        
        return 0
    else
        log_message "FAILED to mount NFS from $pod_ip (Node: $node_name)"
        return 1
    fi
}

main_nfs_discovery() {
    while true; do
        nfs_pods=$(discover_nfs_pods)
        log_message "DEBUG: Discovered NFS pods: $nfs_pods"
        successful_mounts=0
        failed_mounts=0

        # Check all existing mounts for staleness
        for mount_dir in "$CONTROL_PLANE_BASE_MOUNT_DIR"/*; do
            if [ -d "$mount_dir" ] && check_stale_mount "$mount_dir"; then
                unmount_nfs "$mount_dir"
            fi
        done

        for pod_info in $nfs_pods; do
            node_name="${pod_info%:*}"
            pod_ip="${pod_info#*:}"

            if validate_nfs_server "$pod_ip"; then
                if mount_nfs_volume "$pod_ip" "$node_name"; then
                    ((successful_mounts++))
                else
                    ((failed_mounts++))
                fi
            else
                log_message "NFS server not responsive on $pod_ip (Node: $node_name)"
                ((failed_mounts++))
            fi
        done

        log_message "NFS Discovery Cycle Complete: $successful_mounts successful, $failed_mounts failed"
        sleep "$INTERVAL"
    done
}

main_nfs_discovery