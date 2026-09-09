#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-/var/lib/node_exporter/textfile_collector/rent-node.prom}"
TMP="${OUT}.$$"
CONTAINER="${CONTAINER_NAME:-rent-node}"

mkdir -p "$(dirname "$OUT")"

state=0
cpu=0
mem=0
mem_limit=0

if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)"
  if [ "$running" = "true" ]; then
    state=1
    stats="$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "$CONTAINER" 2>/dev/null || true)"
    cpu="$(printf '%s' "$stats" | awk -F'|' '{gsub(/%/,"",$1); print $1+0}')"
    usage="$(printf '%s' "$stats" | awk -F'|' '{print $2}' | awk -F' / ' '{print $1}')"
    limit="$(printf '%s' "$stats" | awk -F'|' '{print $2}' | awk -F' / ' '{print $2}')"

    to_bytes() {
      awk -v v="$1" 'BEGIN {
        n=v+0;
        if (v ~ /TiB$/) n*=1099511627776;
        else if (v ~ /GiB$/) n*=1073741824;
        else if (v ~ /MiB$/) n*=1048576;
        else if (v ~ /KiB$/) n*=1024;
        else if (v ~ /TB$/) n*=1000000000000;
        else if (v ~ /GB$/) n*=1000000000;
        else if (v ~ /MB$/) n*=1000000;
        else if (v ~ /kB$/) n*=1000;
        printf "%.0f", n;
      }'
    }

    mem="$(to_bytes "$usage")"
    mem_limit="$(to_bytes "$limit")"
  fi
fi

cat > "$TMP" <<EOF
# HELP cluster_rent_container_running Whether rent-node is running (1/0).
# TYPE cluster_rent_container_running gauge
cluster_rent_container_running $state
# HELP cluster_rent_container_cpu_percent Docker CPU percentage reported by docker stats.
# TYPE cluster_rent_container_cpu_percent gauge
cluster_rent_container_cpu_percent $cpu
# HELP cluster_rent_container_memory_usage_bytes Docker memory usage reported by docker stats.
# TYPE cluster_rent_container_memory_usage_bytes gauge
cluster_rent_container_memory_usage_bytes $mem
# HELP cluster_rent_container_memory_limit_bytes Docker memory limit reported by docker stats.
# TYPE cluster_rent_container_memory_limit_bytes gauge
cluster_rent_container_memory_limit_bytes $mem_limit
EOF

chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
