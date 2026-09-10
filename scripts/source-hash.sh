#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

{
  printf '%s\0' docker-compose.yml cluster.local.env.example
  find gateway manager monitoring node scripts \
    -type f \
    ! -path 'monitoring/targets/*' \
    ! -path '*/__pycache__/*' \
    ! -name '*.pyc' \
    -print0
} \
  | sort -z \
  | while IFS= read -r -d '' path; do
      [ -f "$path" ] || continue
      sha256sum "$path"
    done \
  | sha256sum \
  | awk '{print $1}'
