#!/usr/bin/env bash
set -euo pipefail

if docker compose version >/dev/null 2>&1; then
  exec docker compose "$@"
fi
if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
  exec docker-compose "$@"
fi

# Last-resort compatibility path for hosts such as CentOS 7 where installing a
# modern Compose plugin may be undesirable. Compose v1.29.2 supports this
# project's Compose features and runs isolated in Docker rather than changing
# host packages.
exec docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  docker/compose:1.29.2 "$@"
