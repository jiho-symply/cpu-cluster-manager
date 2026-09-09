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

./scripts/prepare-master-ssh.sh "$CONFIG"
python3 ./scripts/render-monitoring-targets.py "$CONFIG" monitoring/targets

./scripts/compose.sh config >/dev/null
./scripts/compose.sh up -d --build
./scripts/compose.sh ps

echo
printf '[OK] FastAPI control UI: http://127.0.0.1:%s\n' "$(awk -F= '$1=="UI_PORT"{print $2}' .env | tail -n1 | tr -d '\r' || true)"
printf '[OK] Grafana monitoring : http://127.0.0.1:%s\n' "$(awk -F= '$1=="GRAFANA_PORT"{print $2}' .env | tail -n1 | tr -d '\r' || true)"
echo "[NEXT] install the generated cluster-manager public key and node/install-node.sh on each compute node"
