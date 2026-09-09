#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-config/nodes.yaml}"
KEY="${2:-$HOME/.ssh/cluster-manager_ed25519}"
KNOWN_HOSTS="${3:-$HOME/.ssh/cluster-manager_known_hosts}"

[ -f "$CONFIG" ] || { echo "nodes config not found: $CONFIG" >&2; exit 1; }

mkdir -p "$(dirname "$KEY")" "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KEY")"

if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -f "$KEY" -N '' -C 'cpu-cluster-manager'
fi
[ -f "${KEY}.pub" ] || ssh-keygen -y -f "$KEY" > "${KEY}.pub"

touch "$KNOWN_HOSTS"
chmod 600 "$KEY" "$KNOWN_HOSTS"
chmod 644 "${KEY}.pub"

mapfile -t endpoints < <(
  awk '
    /^[[:space:]]+host:[[:space:]]*/ {
      host=$2; gsub(/^['\''\"]|['\''\"]$/, "", host); port=22; have_host=1; next
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
[ "${#endpoints[@]}" -gt 0 ] || { echo "no nodes found in $CONFIG" >&2; exit 1; }

for endpoint in "${endpoints[@]}"; do
  read -r host port <<<"$endpoint"
  if [ "$port" = "22" ]; then lookup="$host"; else lookup="[$host]:$port"; fi
  if ssh-keygen -F "$lookup" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    echo "[KEEP] trusted host key already exists: $lookup"
    continue
  fi
  echo "[ADD] scanning SSH host key: $lookup"
  ssh-keyscan -T 5 -p "$port" -H "$host" >> "$KNOWN_HOSTS" 2>/dev/null || {
    echo "[ERROR] could not scan SSH host key: $lookup" >&2
    exit 2
  }
done

echo "[OK] private key: $KEY"
echo "[OK] public key : ${KEY}.pub"
echo "[OK] known_hosts: $KNOWN_HOSTS"
echo "[SECURITY] existing host keys are preserved; a changed host key will fail StrictHostKeyChecking instead of being auto-accepted"
