#!/bin/bash

MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_LIMIT_MB=$((MEM_TOTAL_MB * 80 / 100))
SWAP_LIMIT_MB=$((MEM_LIMIT_MB * 120 / 100))

cat <<EOF > /etc/default/docker-memory-limits
DOCKER_MEMORY_MAX=${MEM_LIMIT_MB}M
DOCKER_SWAP_MAX=${SWAP_LIMIT_MB}M
EOF
