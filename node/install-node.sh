#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0 <cluster-ui-public-key-file>" >&2
  exit 1
fi

PUBKEY_FILE="${1:-}"
if [ -z "$PUBKEY_FILE" ] || [ ! -f "$PUBKEY_FILE" ]; then
  echo "usage: sudo $0 <cluster-ui-public-key-file>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 0755 /src/rent/image
cp -a "$SCRIPT_DIR/rent-image/." /src/rent/image/
chmod +x /src/rent/image/*.sh

install -m 0755 "$SCRIPT_DIR/cluster-node-admin" /usr/local/sbin/cluster-node-admin

if ! id cluster-ui >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash cluster-ui
fi
passwd -l cluster-ui >/dev/null 2>&1 || true
install -d -m 0700 -o cluster-ui -g cluster-ui /home/cluster-ui/.ssh
install -m 0600 -o cluster-ui -g cluster-ui "$PUBKEY_FILE" /home/cluster-ui/.ssh/authorized_keys

cat > /etc/sudoers.d/cluster-ui <<'SUDOERS'
cluster-ui ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin summary
cluster-ui ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin start
cluster-ui ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin stop
cluster-ui ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin restart
cluster-ui ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin recreate
cluster-ui ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin reset-password
cluster-ui ALL=(root) NOPASSWD: /usr/local/sbin/cluster-node-admin logs
SUDOERS
chmod 0440 /etc/sudoers.d/cluster-ui
visudo -cf /etc/sudoers.d/cluster-ui >/dev/null

echo "[OK] node management installed"
echo "[OK] SSH user: cluster-ui"
