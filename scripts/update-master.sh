#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-/var/lib/cpu-cluster-manager/cluster.local.env}"
cd "$ROOT"

if [ "$(id -un)" != "ysadmin" ]; then
  echo "[ERROR] run as ysadmin without sudo" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "[ERROR] tracked local changes exist; review them before updating" >&2
  git status --short
  exit 2
fi

git pull --ff-only
bash ./scripts/install-master.sh "$CONFIG"
bash ./scripts/verify-manager-ssh.sh "$CONFIG"
