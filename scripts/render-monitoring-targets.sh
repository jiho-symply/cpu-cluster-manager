#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-cluster.local.env}"
OUTPUT="${2:-monitoring/targets}"
[ -f "$CONFIG" ] || { echo "cluster config not found: $CONFIG" >&2; exit 1; }
mkdir -p "$OUTPUT"

get_cfg() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"
}

CLUSTER="$(get_cfg CLUSTER)"
NODES_SPEC="$(get_cfg NODES)"
[ -n "$CLUSTER" ] || { echo "CLUSTER is empty in $CONFIG" >&2; exit 2; }
[ -n "$NODES_SPEC" ] || { echo "NODES is empty in $CONFIG" >&2; exit 2; }
case "$CLUSTER" in (*[!A-Za-z0-9_.-]*|'') echo "invalid CLUSTER: $CLUSTER" >&2; exit 2;; esac

# Platform is derived from the actual master OS. Both clusters are homogeneous.
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:20.04) PLATFORM="ubuntu20" ;;
  centos:7|centos:7.*) PLATFORM="centos7" ;;
  *) echo "unsupported platform: ${ID:-unknown} ${VERSION_ID:-unknown}" >&2; exit 2 ;;
esac

IFS=',' read -r -a ENTRIES <<< "$NODES_SPEC"
[ "${#ENTRIES[@]}" -gt 0 ] || { echo "no compute nodes in $CONFIG" >&2; exit 2; }
MASTER_NODE="$(hostname -s)"
case "$MASTER_NODE" in (*[!A-Za-z0-9_.-]*|'') echo "invalid master hostname: $MASTER_NODE" >&2; exit 3;; esac

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '[\n' > "$TMP"
printf '  {"targets":["master-node-exporter:9100"],"labels":{"cluster":"%s","platform":"%s","node":"%s","role":"master"}}' \
  "$CLUSTER" "$PLATFORM" "$MASTER_NODE" >> "$TMP"

for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  endpoint="${entry#*@}"
  [ "$endpoint" != "$entry" ] && [ -n "$name" ] && [ -n "$endpoint" ] || {
    echo "invalid NODES entry: $entry (expected name@IPv4)" >&2
    exit 3
  }
  case "$name" in (*[!A-Za-z0-9_.-]*|'') echo "invalid node name: $name" >&2; exit 3;; esac
  case "$endpoint" in (*[!0-9.]*|'') echo "invalid private IPv4 for $name: $endpoint" >&2; exit 3;; esac
  printf ',\n  {"targets":["%s:9100"],"labels":{"cluster":"%s","platform":"%s","node":"%s","role":"compute"}}' \
    "$endpoint" "$CLUSTER" "$PLATFORM" "$name" >> "$TMP"
done
printf '\n]\n' >> "$TMP"

mv "$TMP" "$OUTPUT/node-exporter.json"
chmod 0644 "$OUTPUT/node-exporter.json"
trap - EXIT

echo "[OK] generated Prometheus targets: 1 master + ${#ENTRIES[@]} compute nodes"
echo "[OK] $OUTPUT/node-exporter.json"
