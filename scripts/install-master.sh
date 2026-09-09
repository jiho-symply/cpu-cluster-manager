#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-config/nodes.yaml}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f "$CONFIG" ] || {
  echo "nodes config not found: $CONFIG" >&2
  echo "copy config/nodes.example.yaml or config/nodes.cluster2.example.yaml to config/nodes.yaml first" >&2
  exit 1
}

./scripts/preflight.sh master

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  echo "[CREATED] .env from .env.example"
fi

NODE_COUNT="$(awk '/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {n++} END {print n+0}' "$CONFIG")"
[ "$NODE_COUNT" -gt 0 ] || {
  echo "no compute nodes found in $CONFIG" >&2
  exit 2
}

set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -F= -v k="$key" '$1 != k {print}' .env > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" .env
  chmod 600 .env
}
get_env() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' .env
}

# 18 archive series/node at one sample per 5 minutes is expected to fit well
# below 32 MiB/node for five years. A small 8 MiB WAL segment is configured
# separately in Compose so the shared WAL/head overhead does not dominate the
# requested <100 MB/node archive budget.
ARCHIVE_MB=$((NODE_COUNT * 32))
ARCHIVE_RETENTION_SIZE="${ARCHIVE_MB}MB"
set_env ARCHIVE_RETENTION_SIZE "$ARCHIVE_RETENTION_SIZE"

ADMIN_USERNAME="$(get_env ADMIN_USERNAME)"
ADMIN_USERNAME="${ADMIN_USERNAME:-clusteradmin}"
ADMIN_PASSWORD="$(get_env ADMIN_PASSWORD)"
GENERATED_ADMIN_PASSWORD=0
if [ -z "$ADMIN_PASSWORD" ] || [ "$ADMIN_PASSWORD" = "change-this-password" ]; then
  ADMIN_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  set_env ADMIN_PASSWORD "$ADMIN_PASSWORD"
  GENERATED_ADMIN_PASSWORD=1
fi

UI_PORT="$(get_env UI_PORT)"; UI_PORT="${UI_PORT:-8080}"
GRAFANA_PORT="$(get_env GRAFANA_PORT)"; GRAFANA_PORT="${GRAFANA_PORT:-3000}"

echo "[INFO] compute nodes          : $NODE_COUNT"
echo "[INFO] archive block budget   : $ARCHIVE_RETENTION_SIZE (32 MB/node)"
echo "[INFO] archive max retention  : 5y"
echo "[INFO] archive bucket         : 5m min/avg/max"

./scripts/prepare-master-ssh.sh "$CONFIG"
./scripts/render-monitoring-targets.sh "$CONFIG" monitoring/targets

./scripts/compose.sh config >/dev/null
./scripts/compose.sh up -d --build

wait_http() {
  local name="$1" url="$2" i
  for i in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "[OK] $name healthy: $url"
      return 0
    fi
    sleep 2
  done
  echo "[ERROR] $name health check failed: $url" >&2
  return 1
}

wait_http "FastAPI" "http://127.0.0.1:${UI_PORT}/healthz"
wait_http "Grafana" "http://127.0.0.1:${GRAFANA_PORT}/api/health"

./scripts/compose.sh ps

echo
echo "[OK] master installation complete"
echo "[INFO] FastAPI: http://127.0.0.1:${UI_PORT}"
echo "[INFO] Grafana: http://127.0.0.1:${GRAFANA_PORT}"
if [ "$GENERATED_ADMIN_PASSWORD" -eq 1 ]; then
  echo "[CREDENTIAL] admin_username=$ADMIN_USERNAME"
  echo "[CREDENTIAL] admin_password=$ADMIN_PASSWORD"
  echo "[IMPORTANT] credential is stored in root-readable project .env (mode 600); record it in your password manager"
fi
echo "[INFO] manager private key: $HOME/.ssh/cluster-manager_ed25519"
echo "[INFO] manager public key : $HOME/.ssh/cluster-manager_ed25519.pub"
echo "[NEXT] securely copy the public key to each compute node, clone this repo there, and run node/install-node.sh"
