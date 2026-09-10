#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/var/lib/cpu-cluster-manager/cluster.local.env}"
CONTAINER="cpu-cluster-manager"

[ -f "$CONFIG" ] || { echo "[ERROR] cluster config not found: $CONFIG" >&2; exit 1; }

docker inspect "$CONTAINER" >/dev/null 2>&1 || {
  echo "[ERROR] manager container not found: $CONTAINER" >&2
  exit 2
}
[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)" = "running" ] || {
  echo "[ERROR] manager container is not running" >&2
  exit 2
}

# These are mode-0600 host-owned bind mounts. Test the exact access that the
# FastAPI/NodeSSH process needs before attempting a network connection.
for path in /run/ssh/id_ed25519 /run/ssh/known_hosts; do
  if docker exec "$CONTAINER" test -r "$path"; then
    echo "[OK] manager can read: $path"
  else
    echo "[ERROR] manager cannot read: $path" >&2
    echo "        inspect container capabilities and host file ownership/mode" >&2
    exit 3
  fi
done

# Also make OpenSSH parse the actual private key; test -r alone is not enough.
if ! docker exec "$CONTAINER" ssh-keygen -y -f /run/ssh/id_ed25519 >/dev/null 2>&1; then
  echo "[ERROR] manager OpenSSH cannot read/parse /run/ssh/id_ed25519" >&2
  exit 3
fi

echo "[OK] manager OpenSSH can parse the private key"

NODES_SPEC="$(awk -F= '$1=="NODES" {sub(/^[^=]*=/,""); print; exit}' "$CONFIG")"
[ -n "$NODES_SPEC" ] && [ "$NODES_SPEC" != "EDIT_ME" ] || {
  echo "[ERROR] NODES is not configured" >&2
  exit 2
}

IFS=',' read -r -a ENTRIES <<< "$NODES_SPEC"
for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  endpoint="${entry#*@}"
  [ "$endpoint" != "$entry" ] && [ -n "$name" ] && [ -n "$endpoint" ] || {
    echo "[ERROR] invalid NODES entry: $entry" >&2
    exit 2
  }

  host="$endpoint"
  port=22
  if [[ "$endpoint" == *:* ]] && [[ "${endpoint##*:}" =~ ^[0-9]+$ ]]; then
    host="${endpoint%:*}"
    port="${endpoint##*:}"
  fi

  if SUMMARY="$(docker exec "$CONTAINER" ssh -T \
      -i /run/ssh/id_ed25519 \
      -p "$port" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=yes \
      -o HostKeyAlgorithms=ssh-ed25519 \
      -o UserKnownHostsFile=/run/ssh/known_hosts \
      "ysadmin@$host" summary 2>&1)"; then
    if ! grep -q '^CONTAINER_STATUS=' <<<"$SUMMARY"; then
      echo "[ERROR] manager SSH returned an unexpected summary for $name ($host)" >&2
      printf '%s\n' "$SUMMARY" >&2
      exit 4
    fi
    echo "[OK] manager-container SSH control path: $name ($host:$port)"
  else
    echo "[ERROR] manager-container SSH control path failed: $name ($host:$port)" >&2
    printf '%s\n' "$SUMMARY" >&2
    exit 4
  fi
done

echo "[OK] exact UI SSH path verified for all configured compute nodes"
