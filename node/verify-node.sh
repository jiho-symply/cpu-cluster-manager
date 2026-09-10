#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/cpu-cluster-manager"
ROLE_FILE="$STATE_DIR/role"
STATE="$STATE_DIR/deployed-version"

HOST_ROLE="$(cat "$ROLE_FILE" 2>/dev/null || true)"
if [ -z "$HOST_ROLE" ] && [ -f "$STATE" ]; then
  HOST_ROLE="$(awk -F= '$1=="role" {print $2; exit}' "$STATE" 2>/dev/null || true)"
fi
if [ "$HOST_ROLE" = "master" ] || [ -f "$STATE_DIR/cluster.local.env" ]; then
  echo "[ERROR] this host is a cluster master; node/verify-node.sh is compute-only" >&2
  echo "        use scripts/verify-cluster.sh on a master" >&2
  exit 2
fi
if [ "$HOST_ROLE" != "compute" ]; then
  echo "[ERROR] host is not marked as an installed compute node" >&2
  exit 2
fi

FAIL=0
check_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    echo "[OK] $unit active"
  else
    echo "[FAIL] $unit inactive" >&2
    FAIL=1
  fi
}

if docker inspect rent-node >/dev/null 2>&1; then
  echo "[OK] rent-node: $(docker inspect -f '{{.State.Status}}' rent-node)"
else
  echo "[FAIL] rent-node missing" >&2
  FAIL=1
fi

check_active node-exporter.service
check_active rent-node-metrics.timer

if grep -q '^OnUnitActiveSec=5s$' /etc/systemd/system/rent-node-metrics.timer 2>/dev/null; then
  echo "[OK] rent-node metrics cadence: 5s"
else
  echo "[FAIL] rent-node metrics timer is not configured for 5s" >&2
  FAIL=1
fi

METRICS="$(curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null || true)"
if grep -q '^cluster_rent_container_' <<<"$METRICS"; then
  echo "[OK] node_exporter custom rent metrics"
else
  echo "[FAIL] custom rent metrics missing" >&2
  FAIL=1
fi

if [ -f "$STATE" ]; then
  echo "--- deployed version ---"
  cat "$STATE"
  DEPLOY_COMMIT="$(awk -F= '$1=="commit" {print $2; exit}' "$STATE")"
  if [ -z "$DEPLOY_COMMIT" ] || [ "$DEPLOY_COMMIT" = "unknown" ]; then
    echo "[FAIL] deployed commit is not traceable" >&2
    FAIL=1
  fi
else
  echo "[FAIL] deployed-version missing" >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then exit 10; fi
echo "[OK] compute-node verification passed"
