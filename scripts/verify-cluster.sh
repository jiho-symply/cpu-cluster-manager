#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f "$CONFIG" ] || { echo "cluster config not found: $CONFIG" >&2; exit 1; }

get_cfg() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"
}
NODES_SPEC="$(get_cfg NODES)"
[ -n "$NODES_SPEC" ] && [ "$NODES_SPEC" != "EDIT_ME" ] || { echo "NODES is not configured" >&2; exit 1; }

KEY="$HOME/.ssh/cluster-manager_ed25519"
KNOWN_HOSTS="$HOME/.ssh/cluster-manager_known_hosts"
[ -f "$KEY" ] || { echo "manager private key not found: $KEY" >&2; exit 2; }
[ -f "$KNOWN_HOSTS" ] || { echo "manager known_hosts not found: $KNOWN_HOSTS" >&2; exit 2; }

IFS=',' read -r -a ENTRIES <<< "$NODES_SPEC"
FAIL=0
for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  host="${entry#*@}"
  echo "=== $name ($host) ==="

  if ! ssh -T -i "$KEY" -p 22 \
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
