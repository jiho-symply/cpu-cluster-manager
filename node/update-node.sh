#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/cpu-cluster-manager"
ROLE_FILE="$STATE_DIR/role"

if [ "$(id -un)" != "ysadmin" ]; then
  echo "[ERROR] run this updater as ysadmin without sudo" >&2
  exit 1
fi

HOST_ROLE="$(cat "$ROLE_FILE" 2>/dev/null || true)"
if [ -z "$HOST_ROLE" ] && [ -f "$STATE_DIR/deployed-version" ]; then
  HOST_ROLE="$(awk -F= '$1=="role" {print $2; exit}' "$STATE_DIR/deployed-version" 2>/dev/null || true)"
fi
if [ "$HOST_ROLE" = "master" ] || [ -f "$STATE_DIR/cluster.local.env" ]; then
  echo "[ERROR] this host is a cluster master; node/update-node.sh is compute-only" >&2
  echo "        use scripts/update-master.sh on a master" >&2
  exit 2
fi
if [ "$HOST_ROLE" != "compute" ]; then
  echo "[ERROR] host is not marked as an installed compute node" >&2
  exit 2
fi

# Compute updates are intentionally master-orchestrated. The master creates one
# immutable Git-archive bundle, transfers it over SSH, verifies its checksum on
# the compute, and only then executes the installer from the local snapshot.
echo "[ERROR] direct compute update is disabled to avoid executing the mutable shared NFS working tree" >&2
echo "        run: bash scripts/rollout-all-computes.sh on the cluster master" >&2
exit 2
