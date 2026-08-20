#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-rent-ubuntu:22.04}"
BASE="/src/rent"
TMP_NAME="rent-auth-init-tmp"

mkdir -p "${BASE}/auth"

if [ -f "${BASE}/auth/passwd" ] && \
   [ -f "${BASE}/auth/group" ] && \
   [ -f "${BASE}/auth/shadow" ] && \
   [ -f "${BASE}/auth/gshadow" ]; then
  echo "[SKIP] auth db already exists in ${BASE}/auth"
  exit 0
fi

docker rm -f "${TMP_NAME}" >/dev/null 2>&1 || true
docker create --name "${TMP_NAME}" "${IMAGE_NAME}" >/dev/null

docker cp "${TMP_NAME}:/etc/passwd"  "${BASE}/auth/passwd"
docker cp "${TMP_NAME}:/etc/group"   "${BASE}/auth/group"
docker cp "${TMP_NAME}:/etc/shadow"  "${BASE}/auth/shadow"
docker cp "${TMP_NAME}:/etc/gshadow" "${BASE}/auth/gshadow"

docker rm -f "${TMP_NAME}" >/dev/null

sudo chown root:root \
  "${BASE}/auth/passwd" \
  "${BASE}/auth/group" \
  "${BASE}/auth/shadow" \
  "${BASE}/auth/gshadow"

sudo chmod 644 "${BASE}/auth/passwd" "${BASE}/auth/group"
sudo chmod 600 "${BASE}/auth/shadow" "${BASE}/auth/gshadow"

echo "[OK] initialized auth db under ${BASE}/auth"
