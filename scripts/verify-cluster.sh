#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-config/nodes.yaml}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f "$CONFIG" ] || { echo "nodes config not found: $CONFIG" >&2; exit 1; }

KEY="${SSH_KEY_PATH:-$HOME/.ssh/cluster-manager_ed25519}"
KNOWN_HOSTS="${SSH_KNOWN_HOSTS_PATH:-$HOME/.ssh/cluster-manager_known_hosts}"
[ -f "$KEY" ] || { echo "manager private key not found: $KEY" >&2; exit 2; }
[ -f "$KNOWN_HOSTS" ] || { echo "manager known_hosts not found: $KNOWN_HOSTS" >&2; exit 2; }

mapfile -t NODES < <(awk '
  function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/^['\''\"]|['\''\"]$/, "", s); return s }
  function emit() { if (name != "" || host != "") { print name "\t" host "\t" port; name=""; host=""; port=22 } }
  BEGIN { port=22 }
  /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ { emit(); s=$0; sub(/^[^:]*:/,"",s); name=trim(s); next }
  name != "" && /^[[:space:]]+host:[[:space:]]*/ { s=$0; sub(/^[^:]*:/,"",s); host=trim(s); next }
  name != "" && /^[[:space:]]+port:[[:space:]]*/ { s=$0; sub(/^[^:]*:/,"",s); port=trim(s); next }
  END { emit() }
' "$CONFIG")

FAIL=0
for row in "${NODES[@]}"; do
  IFS=$'\t' read -r name host port <<<"$row"
  echo "=== $name ($host) ==="
  if ! ssh -T -i "$KEY" -p "$port" \
      -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      "ysadmin@$host" summary; then
    echo "[FAIL] SSH control path" >&2
    FAIL=1
  else
    echo "[OK] SSH control path"
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

for c in cpu-cluster-manager cpu-cluster-prometheus-hot cpu-cluster-prometheus-archive cpu-cluster-alertmanager cpu-cluster-grafana; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  if [ "$state" = "running" ]; then
    echo "[OK] master service $c: running"
  else
    echo "[FAIL] master service $c: $state" >&2
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "[ERROR] cluster verification failed" >&2
  exit 10
fi

echo "[OK] end-to-end cluster verification passed"
