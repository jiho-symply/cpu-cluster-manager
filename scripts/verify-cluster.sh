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
NODES_SPEC="$(get_cfg NODES)"
UI_HOST="$(get_cfg UI_HOST)"
UI_PORT="$(get_cfg UI_PORT)"
UI_PORT="${UI_PORT:-8080}"
[ -n "$NODES_SPEC" ] && [ "$NODES_SPEC" != "EDIT_ME" ] || { echo "NODES is not configured" >&2; exit 1; }
[ -n "$UI_HOST" ] && [ "$UI_HOST" != "AUTODETECT" ] || { echo "UI_HOST is not configured" >&2; exit 1; }

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

  if SUMMARY="$(ssh -T -i "$KEY" -p 22 \
      -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      "ysadmin@$host" summary)"; then
    printf '%s\n' "$SUMMARY"
    echo "[OK] SSH control path"
    NODE_COMMIT="$(printf '%s\n' "$SUMMARY" | awk -F= '$1=="DEPLOY_COMMIT" {print $2; exit}')"
    if [ "$NODE_COMMIT" = "$EXPECTED_COMMIT" ]; then
      echo "[OK] deployed commit matches source: ${EXPECTED_COMMIT:0:12}"
    else
      echo "[FAIL] deployment drift: compute=${NODE_COMMIT:--} source=$EXPECTED_COMMIT" >&2
      FAIL=1
    fi
  else
    echo "[FAIL] SSH control path" >&2
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

if curl -fsS --connect-timeout 5 "http://${UI_HOST}:${UI_PORT}/healthz" >/dev/null; then
  echo "[OK] unified management endpoint: http://${UI_HOST}:${UI_PORT}"
else
  echo "[FAIL] unified management endpoint: http://${UI_HOST}:${UI_PORT}" >&2
  FAIL=1
fi

GRAFANA_GATE_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${UI_HOST}:${UI_PORT}/grafana/api/health" || true)"
if [ "$GRAFANA_GATE_STATUS" = "302" ]; then
  echo "[OK] embedded Grafana is protected by management login"
else
  echo "[FAIL] Grafana auth gate returned HTTP ${GRAFANA_GATE_STATUS:--}, expected 302" >&2
  FAIL=1
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
