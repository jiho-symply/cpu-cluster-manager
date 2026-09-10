#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?usage: write-deploy-state.sh <master|compute> [cluster-config]}"
CONFIG="${2:-cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_git() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    sudo -u "$SUDO_USER" git -C "$ROOT" "$@"
  else
    git -C "$ROOT" "$@"
  fi
}

COMMIT="$(repo_git rev-parse HEAD 2>/dev/null)" || {
  echo "[ERROR] cannot resolve deployed Git commit from $ROOT" >&2
  exit 2
}
BRANCH="$(repo_git symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
REMOTE="$(repo_git config --get remote.origin.url 2>/dev/null)" || {
  echo "[ERROR] cannot resolve Git remote.origin.url from $ROOT" >&2
  exit 2
}

CLUSTER="-"
if [ "$ROLE" = "master" ] && [ -f "$CONFIG" ]; then
  CLUSTER="$(awk -F= '$1=="CLUSTER" {sub(/^[^=]*=/,""); print; exit}' "$CONFIG")"
  CLUSTER="${CLUSTER:--}"
elif [ "$ROLE" = "compute" ]; then
  # Both validated clusters are homogeneous by host OS.
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:20.04) CLUSTER="cluster1" ;;
    centos:7|centos:7.*) CLUSTER="cluster2" ;;
  esac
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

case "$ROLE" in
  master)
    DEST_DIR="$HOME/.local/state/cpu-cluster-manager"
    install -d -m 0700 "$DEST_DIR"
    install -m 0600 "$TMP" "$DEST_DIR/deployed-version"
    DEST="$DEST_DIR/deployed-version"
    ;;
  compute)
    [ "$(id -u)" -eq 0 ] || { echo "[ERROR] compute deploy-state write requires root" >&2; exit 2; }
    DEST_DIR="/var/lib/cpu-cluster-manager"
    install -d -m 0755 "$DEST_DIR"
    install -m 0644 "$TMP" "$DEST_DIR/deployed-version"
    DEST="$DEST_DIR/deployed-version"
    ;;
  *)
    echo "[ERROR] unsupported role: $ROLE" >&2
    exit 2
    ;;
esac

echo "[OK] deployed commit recorded: $COMMIT"
echo "[OK] deploy state: $DEST"
