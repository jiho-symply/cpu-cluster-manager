#!/usr/bin/env bash
set -euo pipefail

# Source identity must not depend on a host's locale/collation settings.
# In particular, sort(1) uses locale-sensitive collation by default, which can
# produce a different aggregate hash for the same files on otherwise identical
# compute nodes. Force bytewise ordering everywhere.
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

{
  printf '%s\0' docker-compose.yml cluster.local.env.example
  find gateway manager master monitoring node scripts \
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
    done
