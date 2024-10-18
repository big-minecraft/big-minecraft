#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cd ../

total=$(find images/* -type f | wc -l | xargs)
count=0

for file in images/*; do
  if [ -f "$file" ]; then
    count=$((count + 1))
    image_name=$(basename "$file")

    echo -e "${GREEN}Building and pushing image ${YELLOW}$count${GREEN} of ${YELLOW}$total${GREEN}: wiji1/${YELLOW}$image_name${GREEN}:latest${NC}"
    docker build -f "$file" --platform linux/amd64,linux/arm64 -t "wiji1/$image_name:latest" --push .

    if [ $? -eq 0 ]; then
      echo -e "${GREEN}Successfully built and pushed wiji1/$image_name:latest${NC}"
    else
      echo -e "${RED}Failed to build or push ${YELLOW}wiji1${RED}/$image_name:latest${NC}"
      exit 1
    fi
  fi
done

echo -e "${GREEN}All ${YELLOW}$total${GREEN} images built and pushed successfully.${NC}"
