#!/usr/bin/env bash
set -euo pipefail

NODE_EXPORTER_VERSION="1.12.1"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
INSTALL_DIR="/usr/local/bin"
SERVICE_USER="node-exporter"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/../scripts/preflight.sh" compute

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) NE_ARCH="amd64" ;;
  aarch64) NE_ARCH="arm64" ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
esac

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /sbin/nologin "$SERVICE_USER" 2>/dev/null \
    || useradd -r -M -s /usr/sbin/nologin "$SERVICE_USER"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}.tar.gz"
curl -fsSL "$URL" -o "$TMP/node_exporter.tgz"
tar -xzf "$TMP/node_exporter.tgz" -C "$TMP"
install -m 0755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NE_ARCH}/node_exporter" "$INSTALL_DIR/node_exporter"

install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$TEXTFILE_DIR"
install -m 0755 "$SCRIPT_DIR/rent-node-metrics.sh" "$INSTALL_DIR/rent-node-metrics"

cat > /etc/systemd/system/node-exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$INSTALL_DIR/node_exporter --collector.textfile.directory=$TEXTFILE_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rent-node-metrics.service <<EOF
[Unit]
Description=Write rent-node Docker metrics for node_exporter
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/rent-node-metrics $TEXTFILE_DIR/rent-node.prom
EOF

cat > /etc/systemd/system/rent-node-metrics.timer <<'EOF'
[Unit]
Description=Collect rent-node Docker metrics every 30 seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=rent-node-metrics.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now node-exporter.service
systemctl enable --now rent-node-metrics.timer
systemctl start rent-node-metrics.service

for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:9100/metrics >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:9100/metrics >/dev/null || {
  systemctl --no-pager --full status node-exporter.service >&2 || true
  exit 3
}

if ! curl -fsS http://127.0.0.1:9100/metrics | grep -q '^cluster_rent_container_'; then
  echo "[WARN] node_exporter is healthy but rent-node custom metrics are not visible yet" >&2
fi

echo "[OK] native node_exporter installed: v${NODE_EXPORTER_VERSION}"
echo "[OK] rent-node metrics: systemd timer every 30s"
echo "[OK] monitoring endpoint: :9100/metrics"
echo "[IMPORTANT] allow TCP/9100 only from the corresponding cluster master"
