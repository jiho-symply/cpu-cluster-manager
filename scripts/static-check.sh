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

fail() { echo "[ERROR] $*" >&2; exit 1; }


echo '== shell syntax =='
while IFS= read -r -d '' f; do
  bash -n "$f"
done < <(find . -type f -name '*.sh' -print0)
for f in master/cluster-master-control node/cluster-node-admin node/cluster-node-ssh; do
  bash -n "$f"
done


echo '== host role separation =='
for f in scripts/install-master.sh node/install-node.sh node/update-node.sh node/verify-node.sh; do
  grep -Fq 'ROLE_FILE="$STATE_DIR/role"' "$f" || fail "host role marker guard missing from $f"
done
grep -Fq "printf 'master\\n' > \"\$ROLE_FILE\"" scripts/install-master.sh || fail 'master installer must record master role'
grep -Fq "printf 'compute\\n' > \"\$ROLE_FILE\"" node/install-node.sh || fail 'compute installer must record compute role'
grep -Fq 'this host is a cluster master; refusing compute-node installation' node/install-node.sh || fail 'compute installer must refuse master hosts'
grep -Fq 'this host is a cluster master; node/update-node.sh is compute-only' node/update-node.sh || fail 'compute updater must refuse master hosts'
grep -Fq 'this host is a cluster master; node/verify-node.sh is compute-only' node/verify-node.sh || fail 'compute verifier must refuse master hosts'
echo '[OK] master/compute role guards present'


echo '== CentOS 7 compatibility =='
if grep -R -n --exclude=static-check.sh 'git -C ' scripts node master >/tmp/ccm-git-c-usage.$$ 2>/dev/null; then
  cat /tmp/ccm-git-c-usage.$$ >&2
  rm -f /tmp/ccm-git-c-usage.$$
  fail 'runtime scripts must not use git -C; CentOS 7 Git 1.8.x may not support it'
fi
rm -f /tmp/ccm-git-c-usage.$$
if grep -Fq 'enable --now cpu-cluster-master-control.socket' scripts/install-master.sh; then
  fail 'master control socket install must remain compatible with systemd 219'
fi
echo '[OK] CentOS 7 runtime compatibility guards'


echo '== SSH host-key policy =='
grep -Fq "grep -q ' ssh-ed25519 '" scripts/prepare-master-ssh.sh || fail 'manager known_hosts must verify an ED25519 key exists for each compute'
grep -Fq 'ssh-keyscan -T 5 -p 22 -H -t ed25519' scripts/prepare-master-ssh.sh || fail 'missing ED25519 host keys must be scanned explicitly'
echo '[OK] compute ED25519 host-key coverage enforced'


echo '== rent image APT policy =='
DOCKERFILE=node/rent-image/Dockerfile
MIRROR='http://kr.archive.ubuntu.com/ubuntu'
grep -q '^ARG UBUNTU_MIRROR=http://kr.archive.ubuntu.com/ubuntu$' "$DOCKERFILE" || fail 'rental image must default to the official Korean Ubuntu country mirror'
grep -Fq 'sed -ri "s#https?://(archive|security)\.ubuntu\.com/ubuntu#${UBUNTU_MIRROR}#g"' "$DOCKERFILE" || fail 'rental image mirror rewrite expression is not the validated form'
APT_UPDATE_COUNT="$(grep -c 'apt-get update' "$DOCKERFILE")"
[ "$APT_UPDATE_COUNT" -eq 1 ] || fail "rental image must run apt-get update once, found $APT_UPDATE_COUNT"
MIRROR_TEST_OUTPUT="$(printf '%s\n' 'deb http://archive.ubuntu.com/ubuntu jammy main' 'deb http://security.ubuntu.com/ubuntu jammy-security main' | sed -r "s#https?://(archive|security)\.ubuntu\.com/ubuntu#${MIRROR}#g")"
MIRROR_TEST_EXPECTED="$(printf '%s\n' 'deb http://kr.archive.ubuntu.com/ubuntu jammy main' 'deb http://kr.archive.ubuntu.com/ubuntu jammy-security main')"
[ "$MIRROR_TEST_OUTPUT" = "$MIRROR_TEST_EXPECTED" ] || fail 'Ubuntu mirror rewrite output mismatch'
echo '[OK] Korean Ubuntu mirror rewrite + single apt-get update'


echo '== monitoring update policy =='
grep -Fq 'native node_exporter already installed' node/install-monitoring.sh || fail 'compute updates must reuse an already-installed node_exporter of the pinned version'
grep -Fq '"$NODE_EXPORTER_BIN" --version' node/install-monitoring.sh || fail 'node_exporter reuse must verify the installed version'
grep -Fq 'NE_SHA256=' node/install-monitoring.sh || fail 'new node_exporter downloads must retain checksum verification'
echo '[OK] node_exporter download is first-install/version-change only'


echo '== five-second hot monitoring =='
grep -Eq '^  scrape_interval: 5s$|^  scrape_interval: 5s' monitoring/prometheus/prometheus.yml || fail 'Hot Prometheus scrape interval must be 5s'
grep -Fq 'scrape_timeout: 4s' monitoring/prometheus/prometheus.yml || fail 'Hot Prometheus scrape timeout must remain below the 5s interval'
grep -Fq '  - name: cluster-live' monitoring/prometheus/rules/recording.yml || fail 'live recording group missing'
grep -A2 -F '  - name: cluster-live' monitoring/prometheus/rules/recording.yml | grep -Fq 'interval: 5s' || fail 'live recording rules must evaluate every 5s'
grep -Fq 'irate(node_cpu_seconds_total{mode="idle"}[30s])' monitoring/prometheus/rules/recording.yml || fail 'host CPU must use near-real-time irate for 5s monitoring'
grep -Fq 'OnUnitActiveSec=5s' node/systemd/rent-node-metrics.timer || fail 'rent-node Docker metrics timer must run every 5s'
grep -Fq 'AccuracySec=1s' node/systemd/rent-node-metrics.timer || fail 'rent-node 5s timer accuracy must be 1s'
grep -Fq 'systemctl restart rent-node-metrics.timer' node/install-monitoring.sh || fail 'existing compute timers must restart to adopt the 5s cadence'
echo '[OK] real 5s host + rent-node collection pipeline'


echo '== automatic hot/archive routing =='
grep -Fq 'ARCHIVE_STEP_SECONDS = 300.0' manager/app/prometheus_router.py || fail 'auto router threshold must be exactly 5m'
grep -Fq 'archive_node_cpu_utilization_ratio_avg5m' manager/app/prometheus_router.py || fail 'auto router must map canonical CPU metric to archive average'
grep -Fq 'archive_rent_cpu_cores_avg5m' manager/app/prometheus_router.py || fail 'auto router must map rent CPU metric to archive average'
grep -Fq 'prometheus-router:' docker-compose.yml || fail 'internal Prometheus router service missing'
grep -Fq 'cpu-cluster-prometheus-router' docker-compose.yml || fail 'Prometheus router container name missing'
grep -Fq 'url: http://prometheus-router:8080/prometheus-auto' monitoring/grafana/provisioning/datasources/datasources.yml || fail 'Grafana auto datasource must use the internal router'
grep -Fq 'timeInterval: 5s' monitoring/grafana/provisioning/datasources/datasources.yml || fail 'Grafana auto datasource minimum interval must be 5s'
[ -f monitoring/grafana/dashboards/cluster-monitoring.json ] || fail 'unified monitoring dashboard missing'
[ ! -e monitoring/grafana/dashboards/cluster-recent.json ] || fail 'split Recent dashboard must be removed'
[ ! -e monitoring/grafana/dashboards/cluster-archive.json ] || fail 'split History dashboard must be removed'
grep -Fq '"uid": "cluster-monitoring"' monitoring/grafana/dashboards/cluster-monitoring.json || fail 'unified dashboard UID mismatch'
grep -Fq '"uid": "prometheus-auto"' monitoring/grafana/dashboards/cluster-monitoring.json || fail 'unified dashboard must use Prometheus Auto'
grep -Fq '"5s"' monitoring/grafana/dashboards/cluster-monitoring.json || fail 'Grafana refresh picker must expose 5s'
grep -Fq 'Auto resolution: <5m Hot / ≥5m Archive' manager/app/templates/index.html || fail 'UI must explain automatic resolution policy'
if grep -Fq 'data-monitor-kind=' manager/app/templates/index.html; then fail 'Monitoring UI must not expose separate Recent/History modes'; fi
echo '[OK] one dashboard automatically selects Hot (<5m) or Archive (>=5m)'


echo '== fixed password and federation policy =='
grep -Fq 'ADMIN_PASSWORD=clustermanager' cluster.local.env.example || fail 'fixed campus management password missing from config template'
grep -Fq 'FIXED_MANAGEMENT_PASSWORD="clustermanager"' scripts/install-master.sh || fail 'installer must enforce fixed campus management password'
grep -Fq 'CLUSTER2_PEER_URL="http://165.132.142.133:8080"' scripts/install-master.sh || fail 'Cluster 1 federation peer URL is missing'
grep -Fq 'PEER_HEADER = "X-CCM-Peer-Token"' manager/app/main.py || fail 'peer authentication header is missing'
grep -Fq '@app.get("/api/clusters")' manager/app/main.py || fail 'federated cluster API is missing'
grep -Fq 'f"/{PEER_CLUSTER}/grafana"' manager/app/main.py || fail 'peer Grafana path is missing'
echo '[OK] fixed password + Cluster 1 federation policy'


echo '== safe shutdown policy =='
for f in node/cluster-node-admin node/cluster-node-ssh node/sudoers/cpu-cluster-manager manager/app/ssh_client.py; do
  grep -Fq 'poweroff' "$f" || fail "compute poweroff path missing from $f"
done
grep -Fq 'docker stop -t 30' node/cluster-node-admin || fail 'compute poweroff must stop rent-node first'
grep -Fq 'systemctl poweroff --no-block' node/cluster-node-admin || fail 'compute poweroff must use systemd poweroff'
grep -Fq 'ListenStream=/run/cpu-cluster-manager/master-control.sock' master/systemd/cpu-cluster-master-control.socket || fail 'master control socket unit missing'
grep -Fq 'StandardInput=socket' master/systemd/cpu-cluster-master-control@.service || fail 'master control socket service missing'
grep -Fq 'all compute nodes must be confirmed offline before master shutdown' manager/app/main.py || fail 'master shutdown precondition missing'
grep -Fq 'data-shutdown-computes=' manager/app/templates/index.html || fail 'shutdown-computes UI control missing'
grep -Fq 'data-shutdown-master=' manager/app/templates/index.html || fail 'shutdown-master UI control missing'
echo '[OK] staged compute -> verify offline -> master shutdown path'


echo '== unified management UI policy =='
grep -Fq 'SESSION_COOKIE = "ccm_session"' manager/app/main.py || fail 'password-only session auth is missing'
grep -Fq '@app.post("/api/login")' manager/app/main.py || fail 'password-only login endpoint is missing'
grep -Fq '@app.get("/auth/check")' manager/app/main.py || fail 'gateway auth-check endpoint is missing'
grep -Fq 'data-view="monitoring"' manager/app/templates/index.html || fail 'integrated Monitoring tab is missing'
grep -Fq '<iframe id="grafana-frame"' manager/app/templates/index.html || fail 'embedded Grafana frame is missing'
for c in cluster1 cluster2; do
  conf="gateway/nginx-${c}.conf"
  grep -Fq 'auth_request /_auth;' "$conf" || fail "Grafana auth gate missing from $conf"
  grep -Fq "location /${c}/grafana/" "$conf" || fail "local Grafana path missing from $conf"
  docker run --rm --add-host cluster-manager:127.0.0.1 --add-host grafana:127.0.0.1 -v "$PWD/$conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine nginx -t >/dev/null
done
grep -Fq 'location /cluster2/grafana/' gateway/nginx-cluster1.conf || fail 'Cluster 1 peer Grafana proxy missing'
grep -Fq 'proxy_set_header X-CCM-Peer-Token clustermanager;' gateway/nginx-cluster1.conf || fail 'Cluster 1 peer Grafana authentication missing'
grep -Fq -- '- "${UI_HOST:?set UI_HOST in host-local cluster config}:${UI_PORT:-8080}:8080"' docker-compose.yml || fail 'gateway must be exposed only through UI_HOST:UI_PORT'
grep -Fq -- '- ./gateway/nginx-${CLUSTER}.conf:/etc/nginx/nginx.conf:ro' docker-compose.yml || fail 'gateway config path must use legacy-Compose-safe simple CLUSTER interpolation'
if grep -Fq './gateway/nginx-${CLUSTER:?' docker-compose.yml; then fail 'gateway volume path must not use :? interpolation; Compose 2.6 mis-parses it on CentOS 7'; fi
grep -Fq -- '- "127.0.0.1:${GRAFANA_PORT:-3000}:3000"' docker-compose.yml || fail 'Grafana diagnostic port must remain loopback-only'
grep -Fq 'GF_SERVER_ROOT_URL: http://${UI_HOST}:${UI_PORT:-8080}/${CLUSTER}/grafana/' docker-compose.yml || fail 'Grafana root URL must use legacy-Compose-safe cluster-specific path'
grep -Fq '/run/cpu-cluster-manager/master-control.sock:/run/master-control.sock' docker-compose.yml || fail 'restricted master control socket is not mounted into manager'
echo '[OK] password-only unified Control/Monitoring gateway configuration'


echo '== Python syntax =='
python3 -m compileall -q manager/app


echo '== Grafana dashboard JSON =='
python3 - <<'PY'
import json
from pathlib import Path
paths = list(Path('monitoring/grafana/dashboards').glob('*.json'))
assert [p.name for p in paths] == ['cluster-monitoring.json'], [p.name for p in paths]
for path in paths:
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
[ "$STAMP_COMMIT" = "$(git rev-parse HEAD)" ] || fail 'source stamp commit mismatch'
[ "$STAMP_HASH" = "$CURRENT_HASH" ] || fail 'source stamp hash mismatch'
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
