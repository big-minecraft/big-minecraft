#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to check if buildx is installed
check_buildx() {
    if ! docker buildx version >/dev/null 2>&1; then
        echo -e "${RED}Docker buildx is not installed. Installing...${NC}"
        docker buildx install
        # Create and use a new builder instance
        docker buildx create --use
    fi
}

# Function to ensure builder is running
ensure_builder() {
    if ! docker buildx inspect default >/dev/null 2>&1; then
        echo -e "${YELLOW}Creating new builder instance...${NC}"
        docker buildx create --name multiarch --use
    fi
    docker buildx use multiarch
}

# Main script
cd ../
total=$(find images/* -type f | wc -l | xargs)
count=0

# Check and setup buildx
check_buildx
ensure_builder

# Process each Dockerfile
for file in images/*; do
    if [ -f "$file" ]; then
        count=$((count + 1))
        image_name=$(basename "$file")
        echo -e "${GREEN}Building and pushing image ${YELLOW}$count${GREEN} of ${YELLOW}$total${GREEN}: wiji1/${YELLOW}$image_name${GREEN}:latest${NC}"

        # Build and push using buildx
        if docker buildx build \
            --platform linux/amd64,linux/arm64 \
            -t "wiji1/$image_name:latest" \
            --push \
            -f "$file" \
            .; then
            echo -e "${GREEN}Successfully built and pushed wiji1/$image_name:latest${NC}"
        else
            echo -e "${RED}Failed to build or push wiji1/$image_name:latest${NC}"
            exit 1
        fi
    fi
done

echo -e "${GREEN}All ${YELLOW}$total${GREEN} images built and pushed successfully.${NC}"