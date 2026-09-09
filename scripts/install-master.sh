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
  echo "[IMPORTANT] set ADMIN_PASSWORD in .env before exposing the service"
fi

NODE_COUNT="$(awk '/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {n++} END {print n+0}' "$CONFIG")"
[ "$NODE_COUNT" -gt 0 ] || {
  echo "no compute nodes found in $CONFIG" >&2
  exit 2
}

# Prometheus recommends leaving 15-20% headroom when using retention.size.
# We budget 80 MiB of persistent archive blocks per compute node, keeping the
# total design target below 100 MiB/node after normal WAL/head/compaction overhead.
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

echo "[INFO] compute nodes          : $NODE_COUNT"
echo "[INFO] archive block budget   : $ARCHIVE_RETENTION_SIZE (80MB/node)"
echo "[INFO] archive max retention  : 5y"
echo "[INFO] archive bucket         : 5m min/avg/max"

./scripts/prepare-master-ssh.sh "$CONFIG"
python3 ./scripts/render-monitoring-targets.py "$CONFIG" monitoring/targets

./scripts/compose.sh config >/dev/null
./scripts/compose.sh up -d --build
./scripts/compose.sh ps

echo
printf '[OK] FastAPI control UI: http://127.0.0.1:%s\n' "$(awk -F= '$1=="UI_PORT"{print $2}' .env | tail -n1 | tr -d '\r' || true)"
printf '[OK] Grafana monitoring : http://127.0.0.1:%s\n' "$(awk -F= '$1=="GRAFANA_PORT"{print $2}' .env | tail -n1 | tr -d '\r' || true)"
echo "[NEXT] install the generated cluster-manager public key and node/install-node.sh on each compute node"
