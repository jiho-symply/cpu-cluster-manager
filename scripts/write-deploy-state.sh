#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?usage: write-deploy-state.sh <master|compute> [cluster-config]}"
CONFIG="${2:-cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="/var/lib/cpu-cluster-manager"
DEST="$DEST_DIR/deployed-version"

repo_git() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    sudo -u "$SUDO_USER" git -C "$ROOT" "$@"
  else
    git -C "$ROOT" "$@"
  fi
}

COMMIT="$(repo_git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(repo_git symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
REMOTE="$(repo_git config --get remote.origin.url 2>/dev/null || echo unknown)"
CLUSTER="-"
if [ "$ROLE" = "master" ] && [ -f "$CONFIG" ]; then
  CLUSTER="$(awk -F= '$1=="CLUSTER" {sub(/^[^=]*=/,""); print; exit}' "$CONFIG")"
  CLUSTER="${CLUSTER:--}"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
commit=$COMMIT
branch=$BRANCH
role=$ROLE
cluster=$CLUSTER
host=$(hostname)
deployed_at=$(date -Is)
repository=$REMOTE
EOF

if [ "$(id -u)" -eq 0 ]; then
  install -d -m 0755 "$DEST_DIR"
  install -m 0644 "$TMP" "$DEST"
else
  sudo -n install -d -m 0755 "$DEST_DIR"
  sudo -n install -m 0644 "$TMP" "$DEST"
fi

echo "[OK] deployed commit recorded: $COMMIT"
