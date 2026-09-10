#!/usr/bin/env bash
set -euo pipefail

CONFIG="${CLUSTER_CONFIG:-cluster.local.env}"
[ -f "$CONFIG" ] || {
  echo "cluster config not found: $CONFIG" >&2
  echo "run: bash scripts/install-master.sh" >&2
  exit 1
}

docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose v2 plugin is required" >&2
  exit 1
}

get_cfg() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"
}

NODES="$(get_cfg NODES)"
[ -n "$NODES" ] || { echo "NODES is empty in $CONFIG" >&2; exit 1; }
NODE_COUNT="$(printf '%s' "$NODES" | awk -F',' '{print NF}')"
export ARCHIVE_RETENTION_SIZE="$((NODE_COUNT * 32))MB"

exec docker compose --env-file "$CONFIG" "$@"
