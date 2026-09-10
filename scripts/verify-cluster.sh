#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/var/lib/cpu-cluster-manager/cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_STATE="$ROOT/.cluster-source-state"
cd "$ROOT"
[ -f "$CONFIG" ] || { echo "cluster config not found: $CONFIG" >&2; exit 1; }
[ -f "$SOURCE_STATE" ] || { echo "shared source stamp not found: $SOURCE_STATE" >&2; exit 1; }

get_cfg() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"
}
get_source() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$SOURCE_STATE"
}
CLUSTER="$(get_cfg CLUSTER)"
NODES_SPEC="$(get_cfg NODES)"
UI_HOST="$(get_cfg UI_HOST)"
UI_PORT="$(get_cfg UI_PORT)"
PEER_URL="$(get_cfg PEER_URL)"
UI_PORT="${UI_PORT:-8080}"
[ -n "$NODES_SPEC" ] && [ "$NODES_SPEC" != "EDIT_ME" ] || { echo "NODES is not configured" >&2; exit 1; }
[ -n "$UI_HOST" ] && [ "$UI_HOST" != "AUTODETECT" ] || { echo "UI_HOST is not configured" >&2; exit 1; }
[ "$(get_cfg ADMIN_PASSWORD)" = "clustermanager" ] || { echo "fixed management password policy is not applied" >&2; exit 1; }

KEY="/var/lib/cpu-cluster-manager/ssh/id_ed25519"
KNOWN_HOSTS="/var/lib/cpu-cluster-manager/ssh/known_hosts"
[ -f "$KEY" ] || { echo "manager key not found: $KEY" >&2; exit 2; }
[ -f "$KNOWN_HOSTS" ] || { echo "manager known_hosts not found: $KNOWN_HOSTS" >&2; exit 2; }
EXPECTED_COMMIT="$(get_source commit)"
EXPECTED_HASH="$(get_source source_hash)"
CURRENT_HASH="$(bash "$ROOT/scripts/source-hash.sh")"
if [ "$CURRENT_HASH" != "$EXPECTED_HASH" ]; then
  echo "[FAIL] shared source differs from stamped source; run master installer/update" >&2
  exit 2
fi

IFS=',' read -r -a ENTRIES <<< "$NODES_SPEC"
FAIL=0
for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  host="${entry#*@}"
  echo "=== $name ($host) ==="

  # Verify the exact SSH client/key/known_hosts path used by the web UI.
  if SUMMARY="$(docker exec cpu-cluster-manager ssh -T \
      -i /run/ssh/id_ed25519 -p 22 \
      -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/ssh/known_hosts \
      "ysadmin@$host" summary 2>&1)"; then
    printf '%s\n' "$SUMMARY"
    echo "[OK] manager-container SSH control path"
    NODE_COMMIT="$(printf '%s\n' "$SUMMARY" | awk -F= '$1=="DEPLOY_COMMIT" {print $2; exit}')"
    if [ "$NODE_COMMIT" = "$EXPECTED_COMMIT" ]; then
      echo "[OK] deployed commit matches source: ${EXPECTED_COMMIT:0:12}"
    else
      echo "[FAIL] deployment drift: compute=${NODE_COMMIT:--} source=$EXPECTED_COMMIT" >&2
      FAIL=1
    fi
  else
    printf '%s\n' "$SUMMARY" >&2
    echo "[FAIL] manager-container SSH control path" >&2
    FAIL=1
  fi

  if METRICS="$(curl -fsS --connect-timeout 5 "http://${host}:9100/metrics" 2>/dev/null)" && \
     grep -q '^cluster_rent_container_' <<<"$METRICS"; then
    echo "[OK] node_exporter + rent-node metrics"
  else
    echo "[FAIL] monitoring endpoint ${host}:9100" >&2
    FAIL=1
  fi
  echo
done

for c in \
  cpu-cluster-gateway \
  cpu-cluster-manager \
  cpu-cluster-master-node-exporter \
  cpu-cluster-prometheus-hot \
  cpu-cluster-prometheus-archive \
  cpu-cluster-prometheus-router \
  cpu-cluster-alertmanager \
  cpu-cluster-grafana; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  if [ "$state" = "running" ]; then
    echo "[OK] master service $c: running"
  else
    echo "[FAIL] master service $c: $state" >&2
    FAIL=1
  fi
done

ROUTER_HEALTH="$(docker exec cpu-cluster-prometheus-router python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/prometheus-auto/healthz", timeout=3).read().decode())' 2>/dev/null || true)"
if printf '%s' "$ROUTER_HEALTH" | grep -q 'archive_step_seconds.*300'; then
  echo "[OK] automatic monitoring router: <5m hot / >=5m archive"
else
  echo "[FAIL] automatic monitoring router health check" >&2
  FAIL=1
fi

if systemctl is-active --quiet cpu-cluster-master-control.socket && [ -S /run/cpu-cluster-manager/master-control.sock ]; then
  echo "[OK] restricted master poweroff socket active"
else
  echo "[FAIL] restricted master poweroff socket inactive" >&2
  FAIL=1
fi

if curl -fsS --connect-timeout 5 "http://${UI_HOST}:${UI_PORT}/healthz" >/dev/null; then
  echo "[OK] unified management endpoint: http://${UI_HOST}:${UI_PORT}"
else
  echo "[FAIL] unified management endpoint: http://${UI_HOST}:${UI_PORT}" >&2
  FAIL=1
fi

GRAFANA_GATE_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${UI_HOST}:${UI_PORT}/${CLUSTER}/grafana/api/health" || true)"
if [ "$GRAFANA_GATE_STATUS" = "302" ]; then
  echo "[OK] embedded Grafana is protected by management login"
else
  echo "[FAIL] Grafana auth gate returned HTTP ${GRAFANA_GATE_STATUS:--}, expected 302" >&2
  FAIL=1
fi

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT
LOGIN_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 -c "$COOKIE_JAR" \
  -H 'Content-Type: application/json' \
  -d '{"password":"clustermanager"}' \
  "http://${UI_HOST}:${UI_PORT}/api/login" || true)"
if [ "$LOGIN_STATUS" = "200" ] && curl -fsS --connect-timeout 8 -b "$COOKIE_JAR" "http://${UI_HOST}:${UI_PORT}/api/clusters" >/dev/null; then
  echo "[OK] fixed password-only login and cluster API"
else
  echo "[FAIL] password-only login/API check failed (HTTP ${LOGIN_STATUS:--})" >&2
  FAIL=1
fi
rm -f "$COOKIE_JAR"
trap - EXIT

if [ "$CLUSTER" = "cluster1" ]; then
  if [ "$PEER_URL" = "http://165.132.142.133:8080" ]; then
    echo "[OK] Cluster 1 federation peer configured: $PEER_URL"
  else
    echo "[FAIL] Cluster 1 federation peer mismatch: ${PEER_URL:--}" >&2
    FAIL=1
  fi
fi

TARGET_FILE="monitoring/targets/node-exporter.json"
if [ -f "$TARGET_FILE" ] && grep -q 'master-node-exporter:9100' "$TARGET_FILE"; then
  echo "[OK] master node_exporter target generated"
else
  echo "[FAIL] master node_exporter target missing" >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "[ERROR] cluster verification failed" >&2
  exit 10
fi

echo "[OK] end-to-end cluster verification passed at commit ${EXPECTED_COMMIT:0:12}"
