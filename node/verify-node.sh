#!/usr/bin/env bash
set -euo pipefail

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

METRICS="$(curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null || true)"
if grep -q '^cluster_rent_container_' <<<"$METRICS"; then
  echo "[OK] node_exporter custom rent metrics"
else
  echo "[FAIL] custom rent metrics missing" >&2
  FAIL=1
fi

STATE=/var/lib/cpu-cluster-manager/deployed-version
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
