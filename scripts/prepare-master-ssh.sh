#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-cluster.local.env}"
KEY="${2:-$HOME/.ssh/cluster-manager_ed25519}"
KNOWN_HOSTS="${3:-$HOME/.ssh/cluster-manager_known_hosts}"
[ -f "$CONFIG" ] || { echo "cluster config not found: $CONFIG" >&2; exit 1; }

get_cfg() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"
}
NODES_SPEC="$(get_cfg NODES)"
[ -n "$NODES_SPEC" ] || { echo "NODES is empty in $CONFIG" >&2; exit 1; }

mkdir -p "$(dirname "$KEY")" "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KEY")"
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -f "$KEY" -N '' -C 'cpu-cluster-manager'
fi
[ -f "${KEY}.pub" ] || ssh-keygen -y -f "$KEY" > "${KEY}.pub"
touch "$KNOWN_HOSTS"
chmod 600 "$KEY" "$KNOWN_HOSTS"
chmod 644 "${KEY}.pub"

IFS=',' read -r -a ENTRIES <<< "$NODES_SPEC"
for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  host="${entry#*@}"
  [ "$host" != "$entry" ] && [ -n "$name" ] && [ -n "$host" ] || {
    echo "invalid NODES entry: $entry" >&2
    exit 2
  }
  if ssh-keygen -F "$host" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    echo "[KEEP] trusted host key already exists: $name ($host)"
    continue
  fi
  echo "[ADD] scanning SSH host key: $name ($host)"
  ssh-keyscan -T 5 -p 22 -H "$host" >> "$KNOWN_HOSTS" 2>/dev/null || {
    echo "[ERROR] could not scan SSH host key: $name ($host)" >&2
    exit 2
  }
done

echo "[OK] private key: $KEY"
echo "[OK] public key : ${KEY}.pub"
echo "[OK] known_hosts: $KNOWN_HOSTS"
echo "[SECURITY] existing host keys are preserved; changed keys fail StrictHostKeyChecking"
