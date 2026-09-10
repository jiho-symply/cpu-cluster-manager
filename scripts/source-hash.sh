#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Hash the canonical per-file manifest. source-manifest.sh forces LC_ALL=C so
# identical source bytes always produce the same identity across hosts/locales.
bash "$ROOT/scripts/source-manifest.sh" \
  | sha256sum \
  | awk '{print $1}'
