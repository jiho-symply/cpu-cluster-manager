#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "$(id -un)" != "ysadmin" ]; then
  echo "[ERROR] run this updater as ysadmin without sudo" >&2
  exit 1
fi
if [ ! -f /var/lib/cpu-cluster-manager/manager.pub ]; then
  echo "[ERROR] stored manager public key is missing; run the initial compute installer first" >&2
  exit 2
fi
if [ ! -f "$ROOT/.cluster-source-state" ]; then
  echo "[ERROR] shared source stamp is missing; run the master installer/update first" >&2
  exit 2
fi

exec sudo bash ./node/install-node.sh /var/lib/cpu-cluster-manager/manager.pub
