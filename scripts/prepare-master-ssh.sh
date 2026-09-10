#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/var/lib/cpu-cluster-manager/cluster.local.env}"
KEY="${2:-/var/lib/cpu-cluster-manager/ssh/id_ed25519}"
KNOWN_HOSTS="${3:-/var/lib/cpu-cluster-manager/ssh/known_hosts}"
LEGACY_KEY="$HOME/.ssh/cluster-manager_ed25519"
LEGACY_KNOWN_HOSTS="$HOME/.ssh/cluster-manager_known_hosts"

[ -f "$CONFIG" ] || { echo "cluster config not found: $CONFIG" >&2; exit 1; }

get_cfg() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"
}
NODES_SPEC="$(get_cfg NODES)"
[ -n "$NODES_SPEC" ] || { echo "NODES is empty in $CONFIG" >&2; exit 1; }

mkdir -p "$(dirname "$KEY")" "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KEY")"

if [ ! -f "$KEY" ] && [ -f "$LEGACY_KEY" ]; then
  install -m 0600 "$LEGACY_KEY" "$KEY"
  [ -f "${LEGACY_KEY}.pub" ] && install -m 0644 "${LEGACY_KEY}.pub" "${KEY}.pub"
  echo "[MIGRATE] copied manager key from shared home to host-local state"
fi
if [ ! -f "$KNOWN_HOSTS" ] && [ -f "$LEGACY_KNOWN_HOSTS" ]; then
  install -m 0600 "$LEGACY_KNOWN_HOSTS" "$KNOWN_HOSTS"
  echo "[MIGRATE] copied known_hosts from shared home to host-local state"
fi

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

echo "[OK] manager key: $KEY"
echo "[OK] public key : ${KEY}.pub"
echo "[OK] known_hosts: $KNOWN_HOSTS"
echo "[SECURITY] manager SSH state is host-local; existing host keys are preserved"
