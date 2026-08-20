#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-rent-ubuntu:22.04}"
CONTAINER_NAME="${2:-rent-node}"
BASE="/src/rent"

HOST_SSH_PORT="${HOST_SSH_PORT:-2200}"
HOST_PORT_1="${HOST_PORT_1:-2201}"
HOST_PORT_2="${HOST_PORT_2:-2202}"
HOST_PORT_3="${HOST_PORT_3:-2203}"
HOST_PORT_4="${HOST_PORT_4:-2204}"
HOST_PORT_5="${HOST_PORT_5:-2205}"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --hostname "${CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "${HOST_SSH_PORT}:22" \
  -p "${HOST_PORT_1}:2201" \
  -p "${HOST_PORT_2}:2202" \
  -p "${HOST_PORT_3}:2203" \
  -p "${HOST_PORT_4}:2204" \
  -p "${HOST_PORT_5}:2205" \
  -v "${BASE}/home:/home" \
  -v "${BASE}/work:/workspace" \
  -v "${BASE}/ssh:/persist/ssh" \
  -v "${BASE}/auth:/persist/auth" \
  "${IMAGE_NAME}"

echo "[OK] container started: ${CONTAINER_NAME}"
echo "SSH port: ${HOST_SSH_PORT}"
echo "App ports: ${HOST_PORT_1}-${HOST_PORT_5}"
