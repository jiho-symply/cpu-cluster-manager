#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="ysadmin"
STATE_DIR="/var/lib/cpu-cluster-manager"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo bash $0 <cluster-manager-public-key-file>" >&2
  exit 1
fi

PUBKEY_FILE="${1:-}"
if [ -z "$PUBKEY_FILE" ] || [ ! -f "$PUBKEY_FILE" ]; then
  echo "usage: sudo bash $0 <cluster-manager-public-key-file>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
bash "$ROOT/scripts/preflight.sh" compute

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | awk -F: '{print $6}')"
ADMIN_GROUP="$(id -gn "$ADMIN_USER")"
[ -n "$ADMIN_HOME" ] && [ -d "$ADMIN_HOME" ] || { echo "cannot determine home directory for $ADMIN_USER" >&2; exit 3; }

read -r KEY_TYPE KEY_DATA _ < "$PUBKEY_FILE" || true
if [ -z "${KEY_TYPE:-}" ] || [ -z "${KEY_DATA:-}" ]; then echo "invalid SSH public key file: $PUBKEY_FILE" >&2; exit 4; fi
case "$KEY_TYPE" in
  ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
  *) echo "unsupported SSH public key type: $KEY_TYPE" >&2; exit 4 ;;
esac

RENT_TREE_SHA="$(git -C "$ROOT" rev-parse HEAD:node/rent-image 2>/dev/null || echo unknown)"

# /src/rent/image is a deployed copy only. Runtime data directories are untouched.
install -d -m 0755 /src/rent "$STATE_DIR"
TMP_IMAGE="$(mktemp -d /src/rent/.image.XXXXXX)"
trap 'rm -rf "$TMP_IMAGE"' EXIT
cp -a "$SCRIPT_DIR/rent-image/." "$TMP_IMAGE/"
chmod +x "$TMP_IMAGE"/*.sh
rm -rf /src/rent/image
mv "$TMP_IMAGE" /src/rent/image
trap - EXIT

install -m 0755 "$SCRIPT_DIR/cluster-node-admin" /usr/local/sbin/cluster-node-admin
install -m 0755 "$SCRIPT_DIR/cluster-node-ssh" /usr/local/bin/cluster-node-ssh
install -m 0644 "$PUBKEY_FILE" "$STATE_DIR/manager.pub"

SSH_DIR="$ADMIN_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$SSH_DIR"
TMP_AUTH="$(mktemp)"
trap 'rm -f "$TMP_AUTH"' EXIT
if [ -f "$AUTHORIZED_KEYS" ]; then awk -v key="$KEY_DATA" 'index($0, key) == 0 { print }' "$AUTHORIZED_KEYS" > "$TMP_AUTH"; fi
printf '%s %s %s %s\n' \
  'command="/usr/local/bin/cluster-node-ssh",no-agent-forwarding,no-port-forwarding,no-pty,no-X11-forwarding' \
  "$KEY_TYPE" "$KEY_DATA" 'cpu-cluster-manager' >> "$TMP_AUTH"
install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$TMP_AUTH" "$AUTHORIZED_KEYS"

cat > /etc/sudoers.d/cpu-cluster-manager <<SUDOERS
$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin summary
$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin start
$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin stop
$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin restart
$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin recreate
$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin reset-password
$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin logs
SUDOERS
chmod 0440 /etc/sudoers.d/cpu-cluster-manager
visudo -cf /etc/sudoers.d/cpu-cluster-manager >/dev/null
rm -f /etc/sudoers.d/cluster-ui

IMAGE_NAME="$(awk -F= '$1=="IMAGE_NAME"{print $2; exit}' /src/rent/image/rent.env)"
CONTAINER_NAME="$(awk -F= '$1=="CONTAINER_NAME"{print $2; exit}' /src/rent/image/rent.env)"
IMAGE_NAME="${IMAGE_NAME:-rent-ubuntu:22.04}"
CONTAINER_NAME="${CONTAINER_NAME:-rent-node}"
IMAGE_TREE_SHA="$(docker image inspect "$IMAGE_NAME" --format '{{ index .Config.Labels "io.cpu-cluster-manager.rent-tree" }}' 2>/dev/null || true)"

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 || [ "$IMAGE_TREE_SHA" != "$RENT_TREE_SHA" ]; then
  echo "[INFO] building rental image from Git tree: $RENT_TREE_SHA"
  RENT_TREE_SHA="$RENT_TREE_SHA" /src/rent/image/rentctl.sh build
else
  echo "[SKIP] rental image already matches Git tree: $RENT_TREE_SHA"
fi

FRESH_SETUP=0
if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "[INFO] first-time rent-node setup"
  FRESH_SETUP=1
  /src/rent/image/rentctl.sh setup
else
  echo "[SKIP] existing rent-node and persistent data preserved"
fi

bash "$SCRIPT_DIR/install-monitoring.sh"

docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || { echo "[ERROR] rent-node does not exist after installation" >&2; exit 5; }
CONTAINER_STATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")"
if [ "$FRESH_SETUP" -eq 1 ] && [ "$CONTAINER_STATE" != "running" ]; then echo "[ERROR] fresh rent-node setup is not running: $CONTAINER_STATE" >&2; exit 5; fi
METRICS="$(curl -fsS http://127.0.0.1:9100/metrics)" || exit 6
if ! grep -q '^cluster_rent_container_' <<<"$METRICS"; then echo "[ERROR] rent-node monitoring metrics are not available" >&2; exit 6; fi

bash "$ROOT/scripts/write-deploy-state.sh" compute

echo "[OK] compute-node installation complete"
echo "[OK] SSH control user: $ADMIN_USER"
echo "[OK] rent-node state: $CONTAINER_STATE"
echo "[OK] monitoring: native node_exporter + rent-node metrics on TCP/9100"
echo "[INFO] /src/rent/image is managed from Git and must not be edited locally"
