#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/cpu-cluster-manager"
ROLE_FILE="$STATE_DIR/role"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "$(id -un)" != "ysadmin" ]; then
  echo "[ERROR] run this updater as ysadmin without sudo" >&2
  exit 1
fi

HOST_ROLE="$(cat "$ROLE_FILE" 2>/dev/null || true)"
if [ -z "$HOST_ROLE" ] && [ -f "$STATE_DIR/deployed-version" ]; then
  HOST_ROLE="$(awk -F= '$1=="role" {print $2; exit}' "$STATE_DIR/deployed-version" 2>/dev/null || true)"
fi
if [ "$HOST_ROLE" = "master" ] || [ -f "$STATE_DIR/cluster.local.env" ]; then
  echo "[ERROR] this host is a cluster master; node/update-node.sh is compute-only" >&2
  echo "        use scripts/update-master.sh on a master" >&2
  exit 2
fi
if [ "$HOST_ROLE" != "compute" ]; then
  echo "[ERROR] host is not marked as an installed compute node; run sudo bash node/install-node.sh first" >&2
  exit 2
fi
if [ ! -f "$STATE_DIR/manager.pub" ]; then
  echo "[ERROR] stored manager public key is missing; run the initial compute installer first" >&2
  exit 2
fi
if [ ! -f "$ROOT/.cluster-source-state" ]; then
  echo "[ERROR] shared source stamp is missing; run the master installer/update first" >&2
  exit 2
fi

exec sudo bash ./node/install-node.sh "$STATE_DIR/manager.pub"
