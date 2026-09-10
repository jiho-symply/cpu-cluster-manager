#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/var/lib/cpu-cluster-manager/cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/.cluster-source-state"

command -v git >/dev/null 2>&1 || { echo "[ERROR] git is required on the source host" >&2; exit 1; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[ERROR] $ROOT is not a Git checkout" >&2; exit 1; }

if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
  echo "[ERROR] tracked local changes exist; refusing to stamp an unclean source tree" >&2
  git -C "$ROOT" status --short >&2
  exit 2
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT" symbolic-ref --short -q HEAD || echo detached)"
REMOTE="$(git -C "$ROOT" config --get remote.origin.url || echo unknown)"
RENT_TREE_SHA="$(git -C "$ROOT" rev-parse HEAD:node/rent-image)"
SOURCE_HASH="$(bash "$ROOT/scripts/source-hash.sh")"
CLUSTER="-"
if [ -f "$CONFIG" ]; then
  CLUSTER="$(awk -F= '$1=="CLUSTER" {sub(/^[^=]*=/,""); print; exit}' "$CONFIG")"
  CLUSTER="${CLUSTER:--}"
fi

TMP="$(mktemp "$ROOT/.cluster-source-state.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
commit=$COMMIT
branch=$BRANCH
repository=$REMOTE
rent_tree_sha=$RENT_TREE_SHA
source_hash=$SOURCE_HASH
cluster=$CLUSTER
stamped_at=$(date -Is)
EOF
chmod 0644 "$TMP"
mv "$TMP" "$STATE"
trap - EXIT

echo "[OK] shared source stamped: $COMMIT"
echo "[OK] source hash: $SOURCE_HASH"
