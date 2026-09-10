#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-cluster.local.env}"
cd "$ROOT"

if [ "$(id -un)" != "ysadmin" ]; then
  echo "[ERROR] run as ysadmin without sudo" >&2
  exit 1
fi
[ -f "$CONFIG" ] || { echo "[ERROR] missing $CONFIG" >&2; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "[ERROR] tracked local changes exist; review them before updating" >&2
  git status --short
  exit 2
fi

git pull --ff-only
exec bash ./scripts/install-master.sh "$CONFIG"
