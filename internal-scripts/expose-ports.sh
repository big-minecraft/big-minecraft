#!/bin/bash

NAMESPACE="default"  # Adjust if your services are in a different namespace

# Get all existing NodePort services in the specified namespace
existing_services=$(kubectl get services -n $NAMESPACE -o json | jq -r '.items[] | select(.spec.type=="NodePort") | .metadata.name')

# Get all pods with the label 'minecraft-proxy'
minecraft_pods=$(kubectl get pods -n $NAMESPACE -l app=minecraft-proxy -o json | jq -r '.items[] | .metadata.name')

# Track which services are still in use
active_services=()

# Loop through each pod with the label 'minecraft-proxy'
for pod in $minecraft_pods; do
    # Get the container port of the Pod (assuming the port is defined under 'containers' -> 'ports')
    containerPort=$(kubectl get pod "$pod" -n $NAMESPACE -o json | jq -r '.spec.containers[0].ports[0].containerPort')

    # Check if a corresponding service already exists
    serviceExists=false
    for svc in $existing_services; do
        if [[ $svc == *"$pod"* ]]; then  # Check if service name matches Pod
            serviceExists=true
            active_services+=("$svc")  # Add to active services list
            break
        fi
    done

    # Log the container port for debugging
    echo "Pod: $pod, Container Port: $containerPort, Service Exists: $serviceExists"

    if [ "$serviceExists" = false ]; then
        # Create a new service if it doesn't exist
        echo "Creating service for Pod $pod on port $containerPort"
        kubectl expose pod "$pod" --type=NodePort --name="${pod}-service" --port=$containerPort --target-port=$containerPort -n $NAMESPACE
        if [ $? -eq 0 ]; then
            echo "Service ${pod}-service created successfully."
            active_services+=("${pod}-service")  # Add the newly created service to active services list
        else
            echo "Failed to create service for $pod."
        fi
    else
        echo "Service for $pod already exists."
    fi
done

# Loop through existing services and delete those that are no longer active
for svc in $existing_services; do
    if [[ ! " ${active_services[@]} " =~ " ${svc} " ]] && [[ "$svc" != "nfs-sftp-service" ]]; then
        echo "Deleting unused service: $svc"
        kubectl delete service "$svc" -n $NAMESPACE
        if [ $? -eq 0 ]; then
            echo "Service $svc deleted successfully."
        else
            echo "Failed to delete service $svc."
        fi
    else
        echo "Service $svc is active or is excluded from deletion."
    fi
done