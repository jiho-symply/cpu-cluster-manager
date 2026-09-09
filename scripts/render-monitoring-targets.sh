#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-config/nodes.yaml}"
OUTPUT="${2:-monitoring/targets}"

[ -f "$CONFIG" ] || { echo "nodes config not found: $CONFIG" >&2; exit 1; }
mkdir -p "$OUTPUT"

META="$(awk '
  function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/^['\''\"]|['\''\"]$/, "", s); return s }
  /^[[:space:]]*cluster:[[:space:]]*/ { s=$0; sub(/^[^:]*:/,"",s); print "cluster\t" trim(s) }
  /^[[:space:]]*platform:[[:space:]]*/ { s=$0; sub(/^[^:]*:/,"",s); print "platform\t" trim(s) }
' "$CONFIG")"

CLUSTER="$(printf '%s\n' "$META" | awk -F'\t' '$1=="cluster"{print $2; exit}')"
PLATFORM="$(printf '%s\n' "$META" | awk -F'\t' '$1=="platform"{print $2; exit}')"
[ -n "$CLUSTER" ] || { echo "missing top-level cluster in $CONFIG" >&2; exit 2; }
[ -n "$PLATFORM" ] || { echo "missing top-level platform in $CONFIG" >&2; exit 2; }

case "$CLUSTER" in (*[!A-Za-z0-9_.-]*|'') echo "invalid cluster label: $CLUSTER" >&2; exit 2;; esac
case "$PLATFORM" in (*[!A-Za-z0-9_.-]*|'') echo "invalid platform label: $PLATFORM" >&2; exit 2;; esac

mapfile -t NODES < <(awk '
  function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/^['\''\"]|['\''\"]$/, "", s); return s }
  function emit() { if (name != "" || host != "") { print name "\t" host; name=""; host="" } }
  /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {
    emit(); s=$0; sub(/^[^:]*:/,"",s); name=trim(s); next
  }
  name != "" && /^[[:space:]]+host:[[:space:]]*/ {
    s=$0; sub(/^[^:]*:/,"",s); host=trim(s); next
  }
  END { emit() }
' "$CONFIG")

[ "${#NODES[@]}" -gt 0 ] || { echo "no compute nodes found in $CONFIG" >&2; exit 2; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '[\n' > "$TMP"
for i in "${!NODES[@]}"; do
  IFS=$'\t' read -r name host <<<"${NODES[$i]}"
  [ -n "$name" ] && [ -n "$host" ] || { echo "invalid node entry: ${NODES[$i]}" >&2; exit 3; }
  case "$name" in (*[!A-Za-z0-9_.-]*|'') echo "invalid node name: $name" >&2; exit 3;; esac
  case "$host" in (*[!A-Za-z0-9:._%-]*|'') echo "invalid node host: $host" >&2; exit 3;; esac
  [ "$i" -eq 0 ] || printf ',\n' >> "$TMP"
  printf '  {"targets":["%s:9100"],"labels":{"cluster":"%s","platform":"%s","node":"%s"}}' \
    "$host" "$CLUSTER" "$PLATFORM" "$name" >> "$TMP"
done
printf '\n]\n' >> "$TMP"

mv "$TMP" "$OUTPUT/node-exporter.json"
chmod 0644 "$OUTPUT/node-exporter.json"
trap - EXIT

echo "[OK] monitoring target generated: $OUTPUT/node-exporter.json"
echo "[OK] cluster=$CLUSTER platform=$PLATFORM nodes=${#NODES[@]}"
