#!/usr/bin/env bash
set -euo pipefail

if docker compose version >/dev/null 2>&1; then
  exec docker compose "$@"
fi
if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
  exec docker-compose "$@"
fi

# Compatibility fallback for old hosts (notably CentOS 7). It changes no host
# packages. label=disable is scoped only to this short-lived Compose client so
# an SELinux-enforcing host can expose the Docker socket/project directory.
exec docker run --rm -i \
  --security-opt label=disable \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  docker/compose:1.29.2 "$@"
