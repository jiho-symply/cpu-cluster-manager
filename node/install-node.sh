#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="ysadmin"
NODE_EXPORTER_IMAGE="quay.io/prometheus/node-exporter:v1.12.1"
CADVISOR_IMAGE="ghcr.io/google/cadvisor:v0.60.5"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0 <cluster-manager-public-key-file>" >&2
  exit 1
fi

PUBKEY_FILE="${1:-}"
if [ -z "$PUBKEY_FILE" ] || [ ! -f "$PUBKEY_FILE" ]; then
  echo "usage: sudo $0 <cluster-manager-public-key-file>" >&2
  exit 2
fi

if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  echo "required admin account does not exist: $ADMIN_USER" >&2
  exit 3
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | awk -F: '{print $6}')"
ADMIN_GROUP="$(id -gn "$ADMIN_USER")"

if [ -z "$ADMIN_HOME" ] || [ ! -d "$ADMIN_HOME" ]; then
  echo "cannot determine home directory for $ADMIN_USER" >&2
  exit 3
fi

read -r KEY_TYPE KEY_DATA _ < "$PUBKEY_FILE" || true
if [ -z "${KEY_TYPE:-}" ] || [ -z "${KEY_DATA:-}" ]; then
  echo "invalid SSH public key file: $PUBKEY_FILE" >&2
  exit 4
fi
case "$KEY_TYPE" in
  ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
  *) echo "unsupported SSH public key type: $KEY_TYPE" >&2; exit 4 ;;
esac

install -d -m 0755 /src/rent/image
cp -a "$SCRIPT_DIR/rent-image/." /src/rent/image/
chmod +x /src/rent/image/*.sh

install -m 0755 "$SCRIPT_DIR/cluster-node-admin" /usr/local/sbin/cluster-node-admin
install -m 0755 "$SCRIPT_DIR/cluster-node-ssh" /usr/local/bin/cluster-node-ssh

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

# Read-only monitoring exporters. Restrict ports 9100/8081 so only the Cluster 1 master can reach them.
docker rm -f cluster-node-exporter cluster-cadvisor >/dev/null 2>&1 || true

docker run -d \
  --name cluster-node-exporter \
  --restart unless-stopped \
  --network host \
  --pid host \
  -v /:/host:ro,rslave \
  "$NODE_EXPORTER_IMAGE" \
  --path.rootfs=/host >/dev/null

docker run -d \
  --name cluster-cadvisor \
  --restart unless-stopped \
  --publish 8081:8080 \
  --volume=/:/rootfs:ro \
  --volume=/var/run:/var/run:ro \
  --volume=/sys:/sys:ro \
  --volume=/var/lib/docker/:/var/lib/docker:ro \
  --volume=/dev/disk/:/dev/disk:ro \
  --privileged \
  --device=/dev/kmsg \
  "$CADVISOR_IMAGE" \
  --docker_only=true \
  --store_container_labels=false \
  --housekeeping_interval=10s >/dev/null

echo "[OK] node management installed"
echo "[OK] SSH user: $ADMIN_USER"
echo "[OK] node_exporter: :9100"
echo "[OK] cAdvisor: :8081"
echo "[IMPORTANT] allow :9100 and :8081 only from the Cluster 1 master"
