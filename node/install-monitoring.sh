#!/usr/bin/env bash
set -euo pipefail

NODE_EXPORTER_VERSION="1.12.1"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
INSTALL_DIR="/usr/local/bin"
SERVICE_USER="node-exporter"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/../scripts/preflight.sh" compute

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    NE_ARCH="amd64"
    NE_SHA256="b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63"
    ;;
  aarch64)
    NE_ARCH="arm64"
    NE_SHA256="ad35b605f9954b9f1ffddf5ba054bdc5a98d790b9eae5291e1eeb83f1ecbd0e7"
    ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
esac

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd -r -M -s /sbin/nologin "$SERVICE_USER" 2>/dev/null \
    || useradd -r -M -s /usr/sbin/nologin "$SERVICE_USER"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}.tar.gz"
curl -fL --retry 5 --connect-timeout 10 "$URL" -o "$TMP/node_exporter.tgz"
printf '%s  %s\n' "$NE_SHA256" "$TMP/node_exporter.tgz" | sha256sum -c -
tar -xzf "$TMP/node_exporter.tgz" -C "$TMP"
install -m 0755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}/node_exporter" "$INSTALL_DIR/node_exporter"

install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$TEXTFILE_DIR"
install -m 0755 "$SCRIPT_DIR/rent-node-metrics.sh" "$INSTALL_DIR/rent-node-metrics"

# Systemd definitions are source-controlled; local copies are deployment artifacts only.
install -m 0644 "$SCRIPT_DIR/systemd/node-exporter.service" /etc/systemd/system/node-exporter.service
install -m 0644 "$SCRIPT_DIR/systemd/rent-node-metrics.service" /etc/systemd/system/rent-node-metrics.service
install -m 0644 "$SCRIPT_DIR/systemd/rent-node-metrics.timer" /etc/systemd/system/rent-node-metrics.timer

systemctl daemon-reload
systemctl enable --now node-exporter.service
systemctl enable --now rent-node-metrics.timer
systemctl start rent-node-metrics.service

for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:9100/metrics >/dev/null 2>&1; then break; fi
  sleep 1
done
METRICS="$(curl -fsS http://127.0.0.1:9100/metrics)" || {
  systemctl --no-pager --full status node-exporter.service >&2 || true
  exit 3
}
if ! grep -q '^cluster_rent_container_' <<<"$METRICS"; then
  systemctl --no-pager --full status rent-node-metrics.service >&2 || true
  echo "[ERROR] node_exporter is healthy but rent-node custom metrics are missing" >&2
  exit 4
fi

echo "[OK] native node_exporter installed: v${NODE_EXPORTER_VERSION}"
echo "[OK] Git-tracked systemd units installed"
echo "[OK] rent-node metrics: systemd timer every 30s"
echo "[OK] monitoring endpoint: :9100/metrics"
