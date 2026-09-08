#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-config/nodes.yaml}"
KEY="${2:-$HOME/.ssh/cluster-manager_ed25519}"
KNOWN_HOSTS="${3:-$HOME/.ssh/cluster-manager_known_hosts}"

if [ ! -f "$CONFIG" ]; then
  echo "nodes config not found: $CONFIG" >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY")" "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KEY")"

if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -f "$KEY" -N '' -C 'cpu-cluster-manager'
fi

mapfile -t endpoints < <(
  awk '
    /^[[:space:]]+host:[[:space:]]*/ {
      host=$2; port=22; have_host=1; next
    }
    have_host && /^[[:space:]]+port:[[:space:]]*/ {
      port=$2; print host, port; have_host=0; next
    }
    have_host && /^[[:space:]]*-[[:space:]]+name:/ {
      print host, port; have_host=0
    }
    END { if (have_host) print host, port }
  ' "$CONFIG"
)

if [ "${#endpoints[@]}" -eq 0 ]; then
  echo "no nodes found in $CONFIG" >&2
  exit 1
fi

: > "$KNOWN_HOSTS"
for endpoint in "${endpoints[@]}"; do
  read -r host port <<<"$endpoint"
  ssh-keyscan -p "$port" -H "$host" >> "$KNOWN_HOSTS"
done
chmod 600 "$KEY" "$KNOWN_HOSTS"
chmod 644 "${KEY}.pub"

echo "[OK] private key: $KEY"
echo "[OK] public key : ${KEY}.pub"
echo "[OK] known_hosts: $KNOWN_HOSTS"
echo "[NEXT] install ${KEY}.pub for the existing ysadmin account on each compute node"
