#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="ysadmin"
CONFIG="${1:-cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "$(id -un)" != "$ADMIN_USER" ]; then
  echo "[ERROR] run the master installer as $ADMIN_USER without sudo" >&2
  exit 1
fi

bash ./scripts/preflight.sh master

get_cfg() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"
}
set_cfg() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -F= -v k="$key" -v v="$value" '
    $1 == k { print k "=" v; found=1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  chmod 600 "$CONFIG"
}

if [ ! -f "$CONFIG" ]; then
  cp cluster.local.env.example "$CONFIG"
  chmod 600 "$CONFIG"
  # Infer the logical cluster from the validated master OS for this deployment.
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:20.04) DEFAULT_CLUSTER="cluster1" ;;
    centos:7|centos:7.*) DEFAULT_CLUSTER="cluster2" ;;
    *) DEFAULT_CLUSTER="cluster" ;;
  esac
  set_cfg CLUSTER "$DEFAULT_CLUSTER"
  echo "[CREATED] $CONFIG"
  echo "[NEXT] edit only NODES= in $CONFIG using private management IPs, then run this installer again"
  exit 0
fi
chmod 600 "$CONFIG"

CLUSTER="$(get_cfg CLUSTER)"
NODES="$(get_cfg NODES)"
ADMIN_USERNAME="$(get_cfg ADMIN_USERNAME)"
ADMIN_PASSWORD="$(get_cfg ADMIN_PASSWORD)"
UI_PORT="$(get_cfg UI_PORT)"
GRAFANA_PORT="$(get_cfg GRAFANA_PORT)"

[ -n "$CLUSTER" ] && [ "$CLUSTER" != "AUTODETECT" ] || { echo "[ERROR] CLUSTER is not configured in $CONFIG" >&2; exit 2; }
[ -n "$NODES" ] && [ "$NODES" != "EDIT_ME" ] || { echo "[ERROR] edit NODES= in $CONFIG first" >&2; exit 2; }
ADMIN_USERNAME="${ADMIN_USERNAME:-clusteradmin}"
UI_PORT="${UI_PORT:-8080}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"

GENERATED_ADMIN_PASSWORD=0
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  set_cfg ADMIN_PASSWORD "$ADMIN_PASSWORD"
  GENERATED_ADMIN_PASSWORD=1
fi

IFS=',' read -r -a NODE_ENTRIES <<< "$NODES"
NODE_COUNT="${#NODE_ENTRIES[@]}"
[ "$NODE_COUNT" -gt 0 ] || { echo "[ERROR] no compute nodes in $CONFIG" >&2; exit 2; }

for entry in "${NODE_ENTRIES[@]}"; do
  name="${entry%%@*}"
  host="${entry#*@}"
  [ "$host" != "$entry" ] && [ -n "$name" ] && [ -n "$host" ] || {
    echo "[ERROR] invalid NODES entry: $entry (expected name@privateIPv4)" >&2
    exit 2
  }
done

MONITORED_HOSTS=$((NODE_COUNT + 1))
echo "[INFO] cluster                : $CLUSTER"
echo "[INFO] compute nodes          : $NODE_COUNT"
echo "[INFO] monitored hosts        : $MONITORED_HOSTS (master + compute)"
echo "[INFO] archive block budget   : $((MONITORED_HOSTS * 32))MB (32 MB/monitored host)"
echo "[INFO] archive max retention  : 5y"
echo "[INFO] archive bucket         : 5m min/avg/max"

bash ./scripts/prepare-master-ssh.sh "$CONFIG"
bash ./scripts/render-monitoring-targets.sh "$CONFIG" monitoring/targets

CLUSTER_CONFIG="$CONFIG" bash ./scripts/compose.sh config >/dev/null
CLUSTER_CONFIG="$CONFIG" bash ./scripts/compose.sh up -d --build

wait_http() {
  local name="$1" url="$2" i
  for i in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "[OK] $name healthy: $url"
      return 0
    fi
    sleep 2
  done
  echo "[ERROR] $name health check failed: $url" >&2
  return 1
}

wait_http "FastAPI" "http://127.0.0.1:${UI_PORT}/healthz"
wait_http "Grafana" "http://127.0.0.1:${GRAFANA_PORT}/api/health"
CLUSTER_CONFIG="$CONFIG" bash ./scripts/compose.sh ps
bash ./scripts/write-deploy-state.sh master "$CONFIG"

if [ "$GENERATED_ADMIN_PASSWORD" -eq 1 ]; then
  echo
  echo "[CREDENTIAL] admin_username=$ADMIN_USERNAME"
  echo "[CREDENTIAL] admin_password=$ADMIN_PASSWORD"
  echo "[IMPORTANT] this credential is also stored in $CONFIG (mode 600)"
fi

echo
echo "[OK] master installation complete"
echo "[INFO] operator-managed local config: $ROOT/$CONFIG"
echo "[INFO] FastAPI: http://127.0.0.1:${UI_PORT}"
echo "[INFO] Grafana: http://127.0.0.1:${GRAFANA_PORT}"
echo "[INFO] manager public key: $HOME/.ssh/cluster-manager_ed25519.pub"
echo "[NEXT] copy that public key to each compute node and run: sudo bash node/install-node.sh <pubkey-file>"
