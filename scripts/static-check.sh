#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
PROM_TEST=""
cleanup() {
  if [ -n "$PROM_TEST" ]; then
    docker rm -f "$PROM_TEST" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo '== shell syntax =='
while IFS= read -r -d '' f; do
  bash -n "$f"
done < <(find . -type f -name '*.sh' -print0)

echo '== Python syntax =='
python3 -m compileall -q manager/app

echo '== Grafana dashboard JSON =='
python3 - <<'PY'
import json
from pathlib import Path
for path in Path('monitoring/grafana/dashboards').glob('*.json'):
    json.loads(path.read_text())
    print(f'[OK] {path}')
PY

cat > "$TMP/cluster.env" <<'EOF'
CLUSTER=cluster1
NODES=kfai-cpu-01@192.168.100.11,kfai-cpu-02@192.168.100.12
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=ci-only-password
UI_PORT=8080
GRAFANA_PORT=3000
EOF
cat > "$TMP/ubuntu-os-release" <<'EOF'
ID=ubuntu
VERSION_ID="20.04"
EOF
cat > "$TMP/centos-os-release" <<'EOF'
ID=centos
VERSION_ID="7"
EOF

echo '== target renderer: Ubuntu 20.04 =='
mkdir -p "$TMP/targets-ubuntu"
OS_RELEASE_FILE="$TMP/ubuntu-os-release" bash scripts/render-monitoring-targets.sh "$TMP/cluster.env" "$TMP/targets-ubuntu"

echo '== target renderer: CentOS 7 =='
mkdir -p "$TMP/targets-centos"
OS_RELEASE_FILE="$TMP/centos-os-release" bash scripts/render-monitoring-targets.sh "$TMP/cluster.env" "$TMP/targets-centos"

python3 - "$TMP/targets-ubuntu/node-exporter.json" "$TMP/targets-centos/node-exporter.json" <<'PY'
import json, sys
for fn in sys.argv[1:]:
    data = json.load(open(fn))
    assert len(data) == 3, (fn, len(data))
    assert data[0]['targets'] == ['master-node-exporter:9100']
    assert data[0]['labels']['role'] == 'master'
    assert [x['labels']['role'] for x in data[1:]] == ['compute', 'compute']
    print(f'[OK] {fn}')
PY

echo '== Docker Compose interpolation =='
ARCHIVE_RETENTION_SIZE=96MB docker compose --env-file "$TMP/cluster.env" config >/dev/null

echo '== Prometheus config/rules =='
docker run --rm \
  --entrypoint /bin/promtool \
  -v "$PWD/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$PWD/monitoring/prometheus/rules:/etc/prometheus/rules:ro" \
  -v "$TMP/targets-ubuntu:/etc/prometheus/targets:ro" \
  prom/prometheus:v3.14.0 check config /etc/prometheus/prometheus.yml

docker run --rm \
  --entrypoint /bin/promtool \
  -v "$PWD/monitoring/prometheus-archive/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:v3.14.0 check config /etc/prometheus/prometheus.yml

echo '== Alertmanager config =='
docker run --rm \
  --entrypoint /bin/amtool \
  -v "$PWD/monitoring/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
  prom/alertmanager:v0.34.0 check-config /etc/alertmanager/alertmanager.yml

echo '== image compatibility =='
docker run --rm prom/node-exporter:v1.12.1 --version >/dev/null

echo '== Prometheus storage flag startup =='
PROM_TEST="ccm-prometheus-flag-test-${RANDOM}-$$"
docker run -d --name "$PROM_TEST" \
  prom/prometheus:v3.14.0 \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.wal-segment-size=10MB \
  --storage.tsdb.retention.time=5y \
  --storage.tsdb.retention.size=64MB >/dev/null
sleep 2
PROM_STATE="$(docker inspect -f '{{.State.Status}}' "$PROM_TEST")"
if [ "$PROM_STATE" != "running" ]; then
  echo "[ERROR] Prometheus failed to start with configured storage flags" >&2
  docker logs "$PROM_TEST" >&2 || true
  exit 1
fi
docker rm -f "$PROM_TEST" >/dev/null
PROM_TEST=""

echo '[OK] repository static checks passed'
