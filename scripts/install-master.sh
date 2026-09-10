#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="ysadmin"
STATE_DIR="/var/lib/cpu-cluster-manager"
ROLE_FILE="$STATE_DIR/role"
SSH_DIR="$STATE_DIR/ssh"
DEFAULT_CONFIG="$STATE_DIR/cluster.local.env"
CONFIG="${1:-$DEFAULT_CONFIG}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHED_PUBKEY="$ROOT/.cluster-manager.pub"
LEGACY_CONFIG="$ROOT/cluster.local.env"
LEGACY_KEY="$HOME/.ssh/cluster-manager_ed25519"
LEGACY_KNOWN_HOSTS="$HOME/.ssh/cluster-manager_known_hosts"
cd "$ROOT"

if [ "$(id -un)" != "$ADMIN_USER" ]; then
  echo "[ERROR] run the master installer as $ADMIN_USER without sudo" >&2
  exit 1
fi

bash ./scripts/preflight.sh master

ADMIN_GROUP="$(id -gn "$ADMIN_USER")"
NEED_STATE_MIGRATION=0
if [ ! -d "$STATE_DIR" ] || [ "$(stat -c %U "$STATE_DIR" 2>/dev/null || true)" != "$ADMIN_USER" ]; then
  NEED_STATE_MIGRATION=1
fi
if [ ! -d "$SSH_DIR" ] || [ "$(stat -c %U "$SSH_DIR" 2>/dev/null || true)" != "$ADMIN_USER" ]; then
  NEED_STATE_MIGRATION=1
fi
if [ "$NEED_STATE_MIGRATION" -eq 1 ]; then
  echo "[INFO] preparing host-local master state directory (sudo may prompt once)"
  sudo install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$STATE_DIR" "$SSH_DIR"
  sudo chown -R "$ADMIN_USER:$ADMIN_GROUP" "$STATE_DIR"
fi
chmod 0700 "$STATE_DIR" "$SSH_DIR"

STATE_FSTYPE="$(findmnt -n -T "$STATE_DIR" -o FSTYPE 2>/dev/null || true)"
case "$STATE_FSTYPE" in
  nfs|nfs4|cifs)
    echo "[ERROR] $STATE_DIR is on shared/network storage ($STATE_FSTYPE); refusing to store master secrets there" >&2
    exit 2
    ;;
esac

EXISTING_ROLE="$(cat "$ROLE_FILE" 2>/dev/null || true)"
if [ -z "$EXISTING_ROLE" ] && [ -f "$STATE_DIR/deployed-version" ]; then
  EXISTING_ROLE="$(awk -F= '$1=="role" {print $2; exit}' "$STATE_DIR/deployed-version" 2>/dev/null || true)"
fi
if [ "$EXISTING_ROLE" = "compute" ]; then
  echo "[ERROR] host is already marked as compute; refusing master installation" >&2
  exit 2
fi
printf 'master\n' > "$ROLE_FILE"
chmod 0600 "$ROLE_FILE"

if [ "$CONFIG" = "cluster.local.env" ]; then
  CONFIG="$DEFAULT_CONFIG"
fi
if [ "$CONFIG" != "$DEFAULT_CONFIG" ]; then
  CONFIG_FSTYPE="$(findmnt -n -T "$(dirname "$CONFIG")" -o FSTYPE 2>/dev/null || true)"
  case "$CONFIG_FSTYPE" in
    nfs|nfs4|cifs)
      echo "[ERROR] master config must be host-local, not $CONFIG_FSTYPE: $CONFIG" >&2
      exit 2
      ;;
  esac
fi

if [ ! -f "$CONFIG" ] && [ -f "$LEGACY_CONFIG" ]; then
  install -m 0600 "$LEGACY_CONFIG" "$CONFIG"
  rm -f "$LEGACY_CONFIG"
  echo "[MIGRATE] moved cluster.local.env from shared source checkout to $CONFIG"
fi

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
  install -m 0600 "$tmp" "$CONFIG"
  rm -f "$tmp"
}

if [ ! -f "$CONFIG" ]; then
  install -m 0600 cluster.local.env.example "$CONFIG"
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
UI_HOST="$(get_cfg UI_HOST)"
UI_PORT="$(get_cfg UI_PORT)"
GRAFANA_PORT="$(get_cfg GRAFANA_PORT)"

[ -n "$CLUSTER" ] && [ "$CLUSTER" != "AUTODETECT" ] || { echo "[ERROR] CLUSTER is not configured in $CONFIG" >&2; exit 2; }
[ -n "$NODES" ] && [ "$NODES" != "EDIT_ME" ] || { echo "[ERROR] edit NODES= in $CONFIG first" >&2; exit 2; }
ADMIN_USERNAME="${ADMIN_USERNAME:-clusteradmin}"
UI_PORT="${UI_PORT:-8080}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"

if [ -z "$UI_HOST" ] || [ "$UI_HOST" = "AUTODETECT" ]; then
  UI_HOST="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [ -z "$UI_HOST" ]; then
    UI_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [ -n "$UI_HOST" ] || { echo "[ERROR] could not autodetect UI_HOST; set UI_HOST=<master IPv4> in $CONFIG" >&2; exit 2; }
  set_cfg UI_HOST "$UI_HOST"
  echo "[AUTO] management UI host: $UI_HOST"
fi

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
echo "[INFO] shared source          : $ROOT"
echo "[INFO] host-local state       : $STATE_DIR"
echo "[INFO] host role              : master"
echo "[INFO] management UI          : http://${UI_HOST}:${UI_PORT}"

bash ./scripts/write-source-state.sh "$CONFIG"
bash ./scripts/prepare-master-ssh.sh "$CONFIG" "$SSH_DIR/id_ed25519" "$SSH_DIR/known_hosts"
install -m 0644 "$SSH_DIR/id_ed25519.pub" "$PUBLISHED_PUBKEY"
echo "[OK] manager public key published on shared source: $PUBLISHED_PUBKEY"
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

MASTER_CONTAINERS=(
  cpu-cluster-gateway
  cpu-cluster-manager
  cpu-cluster-master-node-exporter
  cpu-cluster-prometheus-hot
  cpu-cluster-prometheus-archive
  cpu-cluster-alertmanager
  cpu-cluster-grafana
)

check_master_containers_stable() {
  local i name status2 restart2 failed=0
  local -a status1 restart1

  for i in "${!MASTER_CONTAINERS[@]}"; do
    name="${MASTER_CONTAINERS[$i]}"
    status1[$i]="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    restart1[$i]="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo -1)"
  done

  sleep 3

  for i in "${!MASTER_CONTAINERS[@]}"; do
    name="${MASTER_CONTAINERS[$i]}"
    status2="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    restart2="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo -1)"
    if [ "${status1[$i]}" = "running" ] && [ "$status2" = "running" ] && [ "${restart1[$i]}" = "$restart2" ]; then
      echo "[OK] stable container: $name (restarts=$restart2)"
    else
      echo "[ERROR] unstable container: $name status=$status2 restarts=$restart2" >&2
      docker logs --tail 40 "$name" >&2 2>/dev/null || true
      failed=1
    fi
  done

  [ "$failed" -eq 0 ]
}

wait_http "Management UI" "http://${UI_HOST}:${UI_PORT}/healthz"
wait_http "Grafana local backend" "http://127.0.0.1:${GRAFANA_PORT}/api/health"
check_master_containers_stable

CLUSTER_CONFIG="$CONFIG" bash ./scripts/compose.sh ps
bash ./scripts/write-deploy-state.sh master "$CONFIG"

rm -f "$LEGACY_KEY" "${LEGACY_KEY}.pub" "$LEGACY_KNOWN_HOSTS"
rm -f "$HOME/.local/state/cpu-cluster-manager/deployed-version" 2>/dev/null || true

if [ "$GENERATED_ADMIN_PASSWORD" -eq 1 ]; then
  echo
  echo "[CREDENTIAL] management_password=$ADMIN_PASSWORD"
  echo "[IMPORTANT] this password is stored only in $CONFIG (mode 600)"
fi

echo
echo "[OK] master installation complete"
echo "[INFO] operator-managed local config: $CONFIG"
echo "[INFO] Management UI: http://${UI_HOST}:${UI_PORT}"
echo "[INFO] login: password only"
echo "[INFO] Grafana: embedded under http://${UI_HOST}:${UI_PORT}/grafana/"
echo "[INFO] Grafana backend diagnostic: http://127.0.0.1:${GRAFANA_PORT}"
echo "[INFO] manager public key: $SSH_DIR/id_ed25519.pub"
echo "[NEXT] on each compute node: cd $ROOT && sudo bash node/install-node.sh"
