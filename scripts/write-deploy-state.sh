#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?usage: write-deploy-state.sh <master|compute> [cluster-config]}"
CONFIG="${2:-/var/lib/cpu-cluster-manager/cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_STATE="$ROOT/.cluster-source-state"
DEST_DIR="/var/lib/cpu-cluster-manager"
DEST="$DEST_DIR/deployed-version"

[ -f "$SOURCE_STATE" ] || { echo "[ERROR] shared source stamp missing: $SOURCE_STATE" >&2; exit 2; }
get_source() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$SOURCE_STATE"
}
COMMIT="$(get_source commit)"
BRANCH="$(get_source branch)"
REMOTE="$(get_source repository)"
SOURCE_HASH="$(get_source source_hash)"
CLUSTER="$(get_source cluster)"

[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "[ERROR] invalid source commit in $SOURCE_STATE" >&2; exit 2; }
[[ "$SOURCE_HASH" =~ ^[0-9a-f]{64}$ ]] || { echo "[ERROR] invalid source hash in $SOURCE_STATE" >&2; exit 2; }

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
cluster=${CLUSTER:--}
host=$(hostname)
deployed_at=$(date -Is)
repository=$REMOTE
source_hash=$SOURCE_HASH
EOF

case "$ROLE" in
  master)
    [ "$(id -u)" -ne 0 ] || { echo "[ERROR] master deploy-state must be written by ysadmin" >&2; exit 2; }
    install -d -m 0700 "$DEST_DIR"
    install -m 0600 "$TMP" "$DEST"
    ;;
  compute)
    [ "$(id -u)" -eq 0 ] || { echo "[ERROR] compute deploy-state write requires root" >&2; exit 2; }
    install -d -m 0755 "$DEST_DIR"
    install -m 0644 "$TMP" "$DEST"
    ;;
  *)
    echo "[ERROR] unsupported role: $ROLE" >&2
    exit 2
    ;;
esac

echo "[OK] deployed commit recorded: $COMMIT"
echo "[OK] deploy state: $DEST"
