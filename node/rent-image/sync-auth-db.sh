#!/usr/bin/env bash
set -euo pipefail

PERSIST_AUTH_DIR="/persist/auth"

mkdir -p "${PERSIST_AUTH_DIR}"

install -m 0644 -o root -g root /etc/passwd  "${PERSIST_AUTH_DIR}/passwd"
install -m 0644 -o root -g root /etc/group   "${PERSIST_AUTH_DIR}/group"
install -m 0600 -o root -g root /etc/shadow  "${PERSIST_AUTH_DIR}/shadow"
install -m 0600 -o root -g root /etc/gshadow "${PERSIST_AUTH_DIR}/gshadow"

echo "[OK] synced auth db to ${PERSIST_AUTH_DIR}"
