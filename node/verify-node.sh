#!/usr/bin/env bash
set -euo pipefail

FAIL=0
check_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then echo "[OK] $unit active"; else echo "[FAIL] $unit inactive" >&2; FAIL=1; fi
}

if docker inspect rent-node >/dev/null 2>&1; then
  echo "[OK] rent-node: $(docker inspect -f '{{.State.Status}}' rent-node)"
else
  echo "[FAIL] rent-node missing" >&2
  FAIL=1
fi

check_active node-exporter.service
check_active rent-node-metrics.timer

if curl -fsS http://127.0.0.1:9100/metrics | grep -q '^cluster_rent_container_'; then
  echo "[OK] node_exporter custom rent metrics"
else
  echo "[FAIL] custom rent metrics missing" >&2
  FAIL=1
fi

if [ -f /var/lib/cpu-cluster-manager/deployed-version ]; then
  echo "--- deployed version ---"
  cat /var/lib/cpu-cluster-manager/deployed-version
else
  echo "[FAIL] deployed-version missing" >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then exit 10; fi
echo "[OK] compute-node verification passed"
