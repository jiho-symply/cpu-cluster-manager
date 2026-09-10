#!/usr/bin/env bash
set -euo pipefail

BLOCK="$(awk '
  /^  cluster-manager:$/ {inside=1}
  /^  master-node-exporter:$/ {inside=0}
  inside {print}
' docker-compose.yml)"

printf '%s\n' "$BLOCK" | grep -Fq 'cap_drop:' || {
  echo '[ERROR] cluster-manager must drop default capabilities' >&2
  exit 1
}
printf '%s\n' "$BLOCK" | grep -Fq '      - ALL' || {
  echo '[ERROR] cluster-manager must cap_drop ALL' >&2
  exit 1
}
printf '%s\n' "$BLOCK" | grep -Fq 'cap_add:' || {
  echo '[ERROR] cluster-manager needs the narrow SSH-file read capability' >&2
  exit 1
}
printf '%s\n' "$BLOCK" | grep -Fq '      - DAC_READ_SEARCH' || {
  echo '[ERROR] cluster-manager must cap_add only DAC_READ_SEARCH for host-owned mode-0600 SSH files' >&2
  exit 1
}
if printf '%s\n' "$BLOCK" | grep -Eq 'privileged:[[:space:]]*true|/var/run/docker.sock|/:/host'; then
  echo '[ERROR] cluster-manager must not receive privileged, Docker-socket, or host-root access' >&2
  exit 1
fi
printf '%s\n' "$BLOCK" | grep -Fq '/var/lib/cpu-cluster-manager/ssh/id_ed25519:/run/ssh/id_ed25519:ro' || {
  echo '[ERROR] manager private key must remain a read-only bind mount' >&2
  exit 1
}
printf '%s\n' "$BLOCK" | grep -Fq '/var/lib/cpu-cluster-manager/ssh/known_hosts:/run/ssh/known_hosts:ro' || {
  echo '[ERROR] manager known_hosts must remain a read-only bind mount' >&2
  exit 1
}

echo '[OK] manager capability policy: drop ALL, add only DAC_READ_SEARCH for SSH files'
