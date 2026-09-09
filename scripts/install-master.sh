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
  echo "[CREATED] .env from .env.example"
fi

NODE_COUNT="$(awk '/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {n++} END {print n+0}' "$CONFIG")"
[ "$NODE_COUNT" -gt 0 ] || {
  echo "no compute nodes found in $CONFIG" >&2
  exit 2
}

# Keep archive blocks below the requested 100 MB/node design target.
# Prometheus retention.size excludes transient WAL/head/compaction overhead, so
# persistent blocks are capped at 80 MB per compute node.
ARCHIVE_MB=$((NODE_COUNT * 80))
ARCHIVE_RETENTION_SIZE="${ARCHIVE_MB}MB"

set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -F= -v k="$key" '$1 != k {print}' .env > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" .env
}
set_env ARCHIVE_RETENTION_SIZE "$ARCHIVE_RETENTION_SIZE"

ADMIN_PASSWORD="$(awk -F= '$1=="ADMIN_PASSWORD"{sub(/^[^=]*=/,""); print; exit}' .env)"
if [ -z "$ADMIN_PASSWORD" ] || [ "$ADMIN_PASSWORD" = "change-this-password" ]; then
  echo "[ERROR] set a non-default ADMIN_PASSWORD in .env before starting the management stack" >&2
  exit 3
fi

echo "[INFO] compute nodes          : $NODE_COUNT"
echo "[INFO] archive block budget   : $ARCHIVE_RETENTION_SIZE (80 MB/node)"
echo "[INFO] archive max retention  : 5y"
echo "[INFO] archive bucket         : 5m min/avg/max"

./scripts/prepare-master-ssh.sh "$CONFIG"
./scripts/render-monitoring-targets.sh "$CONFIG" monitoring/targets

./scripts/compose.sh config >/dev/null
./scripts/compose.sh up -d --build

# Runtime health checks: fail installation if the stack came up but is unusable.
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

wait_http "FastAPI" "http://127.0.0.1:${UI_PORT:-8080}/healthz"
wait_http "Grafana" "http://127.0.0.1:${GRAFANA_PORT:-3000}/api/health"

./scripts/compose.sh ps

echo
echo "[OK] master installation complete"
echo "[INFO] manager private key: $HOME/.ssh/cluster-manager_ed25519"
echo "[INFO] manager public key : $HOME/.ssh/cluster-manager_ed25519.pub"
echo "[NEXT] on each compute node: clone this repo, then run node/install-node.sh with this public key file"
