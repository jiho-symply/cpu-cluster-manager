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
  rm -f "$ROOT/.cluster-source-state"
  rm -rf "$TMP"
}
trap cleanup EXIT

echo '== shell syntax =='
while IFS= read -r -d '' f; do
  bash -n "$f"
done < <(find . -type f -name '*.sh' -print0)
for f in master/cluster-master-control node/cluster-node-admin node/cluster-node-ssh; do
  bash -n "$f"
done

echo '== host role separation =='
for f in scripts/install-master.sh node/install-node.sh node/update-node.sh node/verify-node.sh; do
  grep -Fq 'ROLE_FILE="$STATE_DIR/role"' "$f" || { echo "[ERROR] host role marker guard missing from $f" >&2; exit 1; }
done
grep -Fq "printf 'master\\n' > \"\$ROLE_FILE\"" scripts/install-master.sh || { echo '[ERROR] master installer must record master role' >&2; exit 1; }
grep -Fq "printf 'compute\\n' > \"\$ROLE_FILE\"" node/install-node.sh || { echo '[ERROR] compute installer must record compute role' >&2; exit 1; }
grep -Fq 'this host is a cluster master; refusing compute-node installation' node/install-node.sh || { echo '[ERROR] compute installer must refuse master hosts' >&2; exit 1; }
grep -Fq 'this host is a cluster master; node/update-node.sh is compute-only' node/update-node.sh || { echo '[ERROR] compute updater must refuse master hosts' >&2; exit 1; }
grep -Fq 'this host is a cluster master; node/verify-node.sh is compute-only' node/verify-node.sh || { echo '[ERROR] compute verifier must refuse master hosts' >&2; exit 1; }
echo '[OK] master/compute role guards present'

echo '== CentOS 7 Git compatibility =='
if grep -R -n --exclude=static-check.sh 'git -C ' scripts node master >/tmp/ccm-git-c-usage.$$ 2>/dev/null; then
  cat /tmp/ccm-git-c-usage.$$ >&2
  rm -f /tmp/ccm-git-c-usage.$$
  echo '[ERROR] runtime scripts must not use git -C; CentOS 7 Git 1.8.x may not support it' >&2
  exit 1
fi
rm -f /tmp/ccm-git-c-usage.$$
echo '[OK] no git -C dependency in runtime scripts'

echo '== rent image APT policy =='
DOCKERFILE=node/rent-image/Dockerfile
MIRROR='http://kr.archive.ubuntu.com/ubuntu'
grep -q '^ARG UBUNTU_MIRROR=http://kr.archive.ubuntu.com/ubuntu$' "$DOCKERFILE" || { echo '[ERROR] rental image must default to the official Korean Ubuntu country mirror' >&2; exit 1; }
grep -Fq 'sed -ri "s#https?://(archive|security)\.ubuntu\.com/ubuntu#${UBUNTU_MIRROR}#g"' "$DOCKERFILE" || { echo '[ERROR] rental image mirror rewrite expression is not the validated form' >&2; exit 1; }
APT_UPDATE_COUNT="$(grep -c 'apt-get update' "$DOCKERFILE")"
[ "$APT_UPDATE_COUNT" -eq 1 ] || { echo "[ERROR] rental image must run apt-get update once, found $APT_UPDATE_COUNT" >&2; exit 1; }
MIRROR_TEST_OUTPUT="$(printf '%s\n' 'deb http://archive.ubuntu.com/ubuntu jammy main' 'deb http://security.ubuntu.com/ubuntu jammy-security main' | sed -r "s#https?://(archive|security)\.ubuntu\.com/ubuntu#${MIRROR}#g")"
MIRROR_TEST_EXPECTED="$(printf '%s\n' 'deb http://kr.archive.ubuntu.com/ubuntu jammy main' 'deb http://kr.archive.ubuntu.com/ubuntu jammy-security main')"
[ "$MIRROR_TEST_OUTPUT" = "$MIRROR_TEST_EXPECTED" ] || { echo '[ERROR] Ubuntu mirror rewrite output mismatch' >&2; exit 1; }
echo '[OK] Korean Ubuntu mirror rewrite + single apt-get update'

echo '== fixed password and federation policy =='
grep -Fq 'ADMIN_PASSWORD=clustermanager' cluster.local.env.example || { echo '[ERROR] fixed campus management password missing from config template' >&2; exit 1; }
grep -Fq 'FIXED_MANAGEMENT_PASSWORD="clustermanager"' scripts/install-master.sh || { echo '[ERROR] installer must enforce fixed campus management password' >&2; exit 1; }
grep -Fq 'CLUSTER2_PEER_URL="http://165.132.142.133:8080"' scripts/install-master.sh || { echo '[ERROR] Cluster 1 federation peer URL is missing' >&2; exit 1; }
grep -Fq 'PEER_HEADER = "X-CCM-Peer-Token"' manager/app/main.py || { echo '[ERROR] peer authentication header is missing' >&2; exit 1; }
grep -Fq '@app.get("/api/clusters")' manager/app/main.py || { echo '[ERROR] federated cluster API is missing' >&2; exit 1; }
grep -Fq 'f"/{PEER_CLUSTER}/grafana"' manager/app/main.py || { echo '[ERROR] peer Grafana path is missing' >&2; exit 1; }
echo '[OK] fixed password + Cluster 1 federation policy'

echo '== safe shutdown policy =='
for f in node/cluster-node-admin node/cluster-node-ssh node/sudoers/cpu-cluster-manager manager/app/ssh_client.py; do
  grep -Fq 'poweroff' "$f" || { echo "[ERROR] compute poweroff path missing from $f" >&2; exit 1; }
done
grep -Fq 'docker stop -t 30' node/cluster-node-admin || { echo '[ERROR] compute poweroff must stop rent-node first' >&2; exit 1; }
grep -Fq 'systemctl poweroff --no-block' node/cluster-node-admin || { echo '[ERROR] compute poweroff must use systemd poweroff' >&2; exit 1; }
grep -Fq 'ListenStream=/run/cpu-cluster-manager/master-control.sock' master/systemd/cpu-cluster-master-control.socket || { echo '[ERROR] master control socket unit missing' >&2; exit 1; }
grep -Fq 'StandardInput=socket' master/systemd/cpu-cluster-master-control@.service || { echo '[ERROR] master control socket service missing' >&2; exit 1; }
grep -Fq 'all compute nodes must be confirmed offline before master shutdown' manager/app/main.py || { echo '[ERROR] master shutdown precondition missing' >&2; exit 1; }
grep -Fq 'data-shutdown-computes=' manager/app/templates/index.html || { echo '[ERROR] shutdown-computes UI control missing' >&2; exit 1; }
grep -Fq 'data-shutdown-master=' manager/app/templates/index.html || { echo '[ERROR] shutdown-master UI control missing' >&2; exit 1; }
echo '[OK] staged compute -> verify offline -> master shutdown path'

echo '== unified management UI policy =='
grep -Fq 'SESSION_COOKIE = "ccm_session"' manager/app/main.py || { echo '[ERROR] password-only session auth is missing' >&2; exit 1; }
grep -Fq '@app.post("/api/login")' manager/app/main.py || { echo '[ERROR] password-only login endpoint is missing' >&2; exit 1; }
grep -Fq '@app.get("/auth/check")' manager/app/main.py || { echo '[ERROR] gateway auth-check endpoint is missing' >&2; exit 1; }
grep -Fq 'data-view="monitoring"' manager/app/templates/index.html || { echo '[ERROR] integrated Monitoring tab is missing' >&2; exit 1; }
grep -Fq '<iframe id="grafana-frame"' manager/app/templates/index.html || { echo '[ERROR] embedded Grafana frame is missing' >&2; exit 1; }
for c in cluster1 cluster2; do
  conf="gateway/nginx-${c}.conf"
  grep -Fq 'auth_request /_auth;' "$conf" || { echo "[ERROR] Grafana auth gate missing from $conf" >&2; exit 1; }
  grep -Fq "location /${c}/grafana/" "$conf" || { echo "[ERROR] local Grafana path missing from $conf" >&2; exit 1; }
  docker run --rm --add-host cluster-manager:127.0.0.1 --add-host grafana:127.0.0.1 -v "$PWD/$conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine nginx -t >/dev/null
done
grep -Fq 'location /cluster2/grafana/' gateway/nginx-cluster1.conf || { echo '[ERROR] Cluster 1 peer Grafana proxy missing' >&2; exit 1; }
grep -Fq 'proxy_set_header X-CCM-Peer-Token clustermanager;' gateway/nginx-cluster1.conf || { echo '[ERROR] Cluster 1 peer Grafana authentication missing' >&2; exit 1; }
grep -Fq -- '- "${UI_HOST:?set UI_HOST in host-local cluster config}:${UI_PORT:-8080}:8080"' docker-compose.yml || { echo '[ERROR] gateway must be exposed only through UI_HOST:UI_PORT' >&2; exit 1; }
grep -Fq -- '- "127.0.0.1:${GRAFANA_PORT:-3000}:3000"' docker-compose.yml || { echo '[ERROR] Grafana diagnostic port must remain loopback-only' >&2; exit 1; }
grep -Fq 'GF_SERVER_ROOT_URL: http://${UI_HOST:?set UI_HOST in host-local cluster config}:${UI_PORT:-8080}/${CLUSTER:?set CLUSTER in host-local cluster config}/grafana/' docker-compose.yml || { echo '[ERROR] Grafana root URL must use cluster-specific unified path' >&2; exit 1; }
grep -Fq '/run/cpu-cluster-manager/master-control.sock:/run/master-control.sock' docker-compose.yml || { echo '[ERROR] restricted master control socket is not mounted into manager' >&2; exit 1; }
echo '[OK] password-only unified Control/Monitoring gateway configuration'

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

cat > "$TMP/cluster1.env" <<'EOF'
CLUSTER=cluster1
NODES=kfai-cpu-01@192.168.100.11,kfai-cpu-02@192.168.100.12
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=clustermanager
UI_HOST=127.0.0.1
UI_PORT=18080
PEER_CLUSTER=cluster2
PEER_URL=http://165.132.142.133:8080
GRAFANA_PORT=13000
EOF
cat > "$TMP/cluster2.env" <<'EOF'
CLUSTER=cluster2
NODES=kfai-cpu-10@172.20.1.4,kfai-cpu-11@172.20.1.5
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=clustermanager
UI_HOST=127.0.0.1
UI_PORT=18080
PEER_CLUSTER=
PEER_URL=
GRAFANA_PORT=13000
EOF
cat > "$TMP/ubuntu-os-release" <<'EOF'
ID=ubuntu
VERSION_ID="20.04"
EOF
cat > "$TMP/centos-os-release" <<'EOF'
ID=centos
VERSION_ID="7"
EOF

echo '== shared source stamp =='
bash scripts/write-source-state.sh "$TMP/cluster1.env"
STAMP_COMMIT="$(awk -F= '$1=="commit" {print $2; exit}' .cluster-source-state)"
STAMP_HASH="$(awk -F= '$1=="source_hash" {print $2; exit}' .cluster-source-state)"
CURRENT_HASH="$(bash scripts/source-hash.sh)"
[ "$STAMP_COMMIT" = "$(git rev-parse HEAD)" ] || { echo '[ERROR] source stamp commit mismatch' >&2; exit 1; }
[ "$STAMP_HASH" = "$CURRENT_HASH" ] || { echo '[ERROR] source stamp hash mismatch' >&2; exit 1; }
echo "[OK] source stamp: ${STAMP_COMMIT:0:12} / ${STAMP_HASH:0:12}"

echo '== target renderer: Ubuntu 20.04 =='
mkdir -p "$TMP/targets-ubuntu"
OS_RELEASE_FILE="$TMP/ubuntu-os-release" bash scripts/render-monitoring-targets.sh "$TMP/cluster1.env" "$TMP/targets-ubuntu"

echo '== target renderer: CentOS 7 =='
mkdir -p "$TMP/targets-centos"
OS_RELEASE_FILE="$TMP/centos-os-release" bash scripts/render-monitoring-targets.sh "$TMP/cluster2.env" "$TMP/targets-centos"

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
ARCHIVE_RETENTION_SIZE=96MB docker compose --env-file "$TMP/cluster1.env" config >/dev/null
ARCHIVE_RETENTION_SIZE=96MB docker compose --env-file "$TMP/cluster2.env" config >/dev/null
echo '[OK] Cluster 1 and Cluster 2 Compose render'

echo '== Prometheus config/rules =='
docker run --rm --entrypoint /bin/promtool -v "$PWD/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$PWD/monitoring/prometheus/rules:/etc/prometheus/rules:ro" -v "$TMP/targets-ubuntu:/etc/prometheus/targets:ro" prom/prometheus:v3.14.0 check config /etc/prometheus/prometheus.yml
docker run --rm --entrypoint /bin/promtool -v "$PWD/monitoring/prometheus-archive/prometheus.yml:/etc/prometheus/prometheus.yml:ro" prom/prometheus:v3.14.0 check config /etc/prometheus/prometheus.yml

echo '== Alertmanager config =='
docker run --rm --entrypoint /bin/amtool -v "$PWD/monitoring/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" prom/alertmanager:v0.34.0 check-config /etc/alertmanager/alertmanager.yml

echo '== image compatibility =='
docker run --rm prom/node-exporter:v1.12.1 --version >/dev/null

echo '== Prometheus storage flag startup =='
PROM_TEST="ccm-prometheus-flag-test-${RANDOM}-$$"
docker run -d --name "$PROM_TEST" -v "$PWD/monitoring/prometheus-archive/prometheus.yml:/etc/prometheus/prometheus.yml:ro" prom/prometheus:v3.14.0 --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.wal-segment-size=10MB --storage.tsdb.retention.time=5y --storage.tsdb.retention.size=64MB >/dev/null
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
