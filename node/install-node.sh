#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="ysadmin"
STATE_DIR="/var/lib/cpu-cluster-manager"
ROLE_FILE="$STATE_DIR/role"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_STATE="$ROOT/.cluster-source-state"
DEFAULT_PUBKEY="$ROOT/.cluster-manager.pub"
PUBKEY_FILE="${1:-$DEFAULT_PUBKEY}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo bash $0 [cluster-manager-public-key-file]" >&2
  exit 1
fi

EXISTING_ROLE="$(cat "$ROLE_FILE" 2>/dev/null || true)"
if [ -z "$EXISTING_ROLE" ] && [ -f "$STATE_DIR/deployed-version" ]; then
  EXISTING_ROLE="$(awk -F= '$1=="role" {print $2; exit}' "$STATE_DIR/deployed-version" 2>/dev/null || true)"
fi
if [ "$EXISTING_ROLE" = "master" ] || [ -f "$STATE_DIR/cluster.local.env" ] || docker inspect cpu-cluster-manager >/dev/null 2>&1; then
  echo "[ERROR] this host is a cluster master; refusing compute-node installation" >&2
  echo "        use scripts/install-master.sh or scripts/update-master.sh on a master" >&2
  exit 2
fi

if [ -z "$PUBKEY_FILE" ] || [ ! -f "$PUBKEY_FILE" ]; then
  echo "[ERROR] manager public key not found: $PUBKEY_FILE" >&2
  echo "        run the master installer first; it publishes $DEFAULT_PUBKEY on the shared source" >&2
  exit 2
fi

# Freshly discovered CentOS 7 computes may still carry Docker 18.09. Normalize
# only the supported docker-ce package family to the same validated 20.10.17
# baseline used by the existing CentOS nodes. This preserves /var/lib/docker
# and any existing rent-node container identity/data.
bash "$ROOT/scripts/ensure-compute-docker.sh"
bash "$ROOT/scripts/preflight.sh" compute

[ -f "$SOURCE_STATE" ] || {
  echo "[ERROR] shared source stamp missing: $SOURCE_STATE" >&2
  echo "        run the master installer/update first" >&2
  exit 3
}
get_source() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$SOURCE_STATE"
}
DEPLOY_COMMIT="$(get_source commit)"
RENT_TREE_SHA="$(get_source rent_tree_sha)"
STAMPED_SOURCE_HASH="$(get_source source_hash)"
[[ "$DEPLOY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "[ERROR] invalid source commit stamp" >&2; exit 3; }
[[ "$RENT_TREE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "[ERROR] invalid rent-image tree stamp" >&2; exit 3; }
[[ "$STAMPED_SOURCE_HASH" =~ ^[0-9a-f]{64}$ ]] || { echo "[ERROR] invalid source hash stamp" >&2; exit 3; }
CURRENT_SOURCE_HASH="$(bash "$ROOT/scripts/source-hash.sh")"
if [ "$CURRENT_SOURCE_HASH" != "$STAMPED_SOURCE_HASH" ]; then
  echo "[ERROR] shared source changed after master stamp; refusing deployment" >&2
  echo "        stamped=$STAMPED_SOURCE_HASH" >&2
  echo "        current=$CURRENT_SOURCE_HASH" >&2
  echo "        run the master installer/update to restamp the source" >&2
  exit 3
fi
echo "[INFO] source commit: $DEPLOY_COMMIT"
echo "[INFO] source hash  : $CURRENT_SOURCE_HASH"
echo "[INFO] rent-image tree: $RENT_TREE_SHA"

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | awk -F: '{print $6}')"
ADMIN_GROUP="$(id -gn "$ADMIN_USER")"
[ -n "$ADMIN_HOME" ] && [ -d "$ADMIN_HOME" ] || { echo "cannot determine home directory for $ADMIN_USER" >&2; exit 3; }

read -r KEY_TYPE KEY_DATA _ < "$PUBKEY_FILE" || true
if [ -z "${KEY_TYPE:-}" ] || [ -z "${KEY_DATA:-}" ]; then echo "invalid SSH public key file: $PUBKEY_FILE" >&2; exit 4; fi
case "$KEY_TYPE" in
  ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
  *) echo "unsupported SSH public key type: $KEY_TYPE" >&2; exit 4 ;;
esac

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
MANAGER_PUB="$STATE_DIR/manager.pub"
if [ -e "$MANAGER_PUB" ] && [ "$PUBKEY_FILE" -ef "$MANAGER_PUB" ]; then
  chmod 0644 "$MANAGER_PUB"
  echo "[KEEP] manager public key already stored: $MANAGER_PUB"
else
  install -m 0644 "$PUBKEY_FILE" "$MANAGER_PUB"
fi

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

install -m 0440 "$SCRIPT_DIR/sudoers/cpu-cluster-manager" /etc/sudoers.d/cpu-cluster-manager
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
printf 'compute\n' > "$ROLE_FILE"
chmod 0644 "$ROLE_FILE"

echo "[OK] compute-node installation complete"
echo "[OK] SSH control user: $ADMIN_USER"
echo "[OK] rent-node state: $CONTAINER_STATE"
echo "[OK] monitoring: native node_exporter + rent-node metrics on TCP/9100"
echo "[INFO] host role: compute"
echo "[INFO] /src/rent/image is managed from the shared Git source and must not be edited locally"
