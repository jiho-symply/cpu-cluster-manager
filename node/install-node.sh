#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="ysadmin"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0 <cluster-manager-public-key-file>" >&2
  exit 1
fi

PUBKEY_FILE="${1:-}"
if [ -z "$PUBKEY_FILE" ] || [ ! -f "$PUBKEY_FILE" ]; then
  echo "usage: sudo $0 <cluster-manager-public-key-file>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/../scripts/preflight.sh" compute

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | awk -F: '{print $6}')"
ADMIN_GROUP="$(id -gn "$ADMIN_USER")"
[ -n "$ADMIN_HOME" ] && [ -d "$ADMIN_HOME" ] || {
  echo "cannot determine home directory for $ADMIN_USER" >&2
  exit 3
}

read -r KEY_TYPE KEY_DATA _ < "$PUBKEY_FILE" || true
if [ -z "${KEY_TYPE:-}" ] || [ -z "${KEY_DATA:-}" ]; then
  echo "invalid SSH public key file: $PUBKEY_FILE" >&2
  exit 4
fi
case "$KEY_TYPE" in
  ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
  *) echo "unsupported SSH public key type: $KEY_TYPE" >&2; exit 4 ;;
esac

# Install/update the managed rent image source without touching persistent renter data.
install -d -m 0755 /src/rent/image
cp -a "$SCRIPT_DIR/rent-image/." /src/rent/image/
chmod +x /src/rent/image/*.sh

install -m 0755 "$SCRIPT_DIR/cluster-node-admin" /usr/local/sbin/cluster-node-admin
install -m 0755 "$SCRIPT_DIR/cluster-node-ssh" /usr/local/bin/cluster-node-ssh

# Add only the dedicated manager key, preserving existing human/admin keys.
SSH_DIR="$ADMIN_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$SSH_DIR"
TMP_AUTH="$(mktemp)"
trap 'rm -f "$TMP_AUTH"' EXIT
if [ -f "$AUTHORIZED_KEYS" ]; then
  awk -v key="$KEY_DATA" 'index($0, key) == 0 { print }' "$AUTHORIZED_KEYS" > "$TMP_AUTH"
fi
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

# Bootstrap the rental container only when it does not already exist.
# Re-running this installer therefore never resets /src/rent or renter credentials.
IMAGE_NAME="$(awk -F= '$1=="IMAGE_NAME"{print $2; exit}' /src/rent/image/rent.env)"
CONTAINER_NAME="$(awk -F= '$1=="CONTAINER_NAME"{print $2; exit}' /src/rent/image/rent.env)"
IMAGE_NAME="${IMAGE_NAME:-rent-ubuntu:22.04}"
CONTAINER_NAME="${CONTAINER_NAME:-rent-node}"

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "[INFO] building rental image: $IMAGE_NAME"
  /src/rent/image/rentctl.sh build
else
  echo "[SKIP] rental image already exists: $IMAGE_NAME"
fi

if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "[INFO] first-time rent-node setup"
  /src/rent/image/rentctl.sh setup
else
  echo "[SKIP] existing rent-node preserved"
fi

"$SCRIPT_DIR/install-monitoring.sh"

# Final runtime verification.
docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || {
  echo "[ERROR] rent-node does not exist after installation" >&2
  exit 5
}
CONTAINER_STATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")"
[ "$CONTAINER_STATE" = "running" ] || {
  echo "[ERROR] rent-node is not running after installation: $CONTAINER_STATE" >&2
  exit 5
}
curl -fsS http://127.0.0.1:9100/metrics | grep -q '^cluster_rent_container_' || {
  echo "[ERROR] rent-node monitoring metrics are not available" >&2
  exit 6
}

echo "[OK] compute-node installation complete"
echo "[OK] SSH control user: $ADMIN_USER"
echo "[OK] rent-node state: $CONTAINER_STATE"
echo "[OK] monitoring: native node_exporter + rent-node metrics on TCP/9100"
