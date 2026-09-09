#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-all}"
ADMIN_USER="${ADMIN_USER:-ysadmin}"
MIN_DOCKER_API="1.40"

say() { printf '%-24s %s\n' "$1" "$2"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

[ -r /etc/os-release ] || fail "/etc/os-release not found"
# shellcheck disable=SC1091
. /etc/os-release

PLATFORM="unsupported"
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:20.04) PLATFORM="ubuntu20" ;;
  centos:7|centos:7.*) PLATFORM="centos7" ;;
esac

say "role" "$ROLE"
say "platform" "$PLATFORM (${PRETTY_NAME:-unknown})"
say "kernel" "$(uname -r)"
say "architecture" "$(uname -m)"

[ "$PLATFORM" != "unsupported" ] || fail "supported OS: Ubuntu 20.04 or CentOS 7"
command -v systemctl >/dev/null 2>&1 || fail "systemd/systemctl is required"
id "$ADMIN_USER" >/dev/null 2>&1 || fail "required admin account is missing: $ADMIN_USER"
say "admin account" "$ADMIN_USER"

command -v docker >/dev/null 2>&1 || fail "Docker is required but not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
DOCKER_API="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
say "Docker Engine" "${DOCKER_VERSION:-unknown}"
say "Docker API" "${DOCKER_API:-unknown}"
if [ -n "$DOCKER_API" ] && ! version_ge "$DOCKER_API" "$MIN_DOCKER_API"; then
  warn "Docker API $DOCKER_API is older than the compatibility baseline $MIN_DOCKER_API. Container control may work, but validate before deployment."
fi

CGROUP_FS="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
case "$CGROUP_FS" in
  cgroup2fs) CGROUP_MODE="v2" ;;
  tmpfs) CGROUP_MODE="v1" ;;
  *) CGROUP_MODE="$CGROUP_FS" ;;
esac
say "cgroup" "$CGROUP_MODE"

if [ "$PLATFORM" = "centos7" ]; then
  KERNEL="$(uname -r)"
  if [[ "$KERNEL" =~ ^3\.10\.0-([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -lt 366 ]; then
    warn "CentOS/RHEL 7 kernel $KERNEL is older than 3.10.0-366; upgrade the kernel before container monitoring."
  fi
fi

if [ "$ROLE" = "master" ] || [ "$ROLE" = "all" ]; then
  if docker compose version >/dev/null 2>&1; then
    say "Compose" "$(docker compose version --short 2>/dev/null || docker compose version)"
  elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    say "Compose" "$(docker-compose version --short 2>/dev/null || docker-compose version)"
  else
    fail "Docker Compose is required on a master node"
  fi
fi

if [ "$ROLE" = "compute" ] || [ "$ROLE" = "all" ]; then
  RENT_STATE="$(docker inspect -f '{{.State.Status}}' rent-node 2>/dev/null || echo missing)"
  say "rent-node" "$RENT_STATE"
  for cmd in curl tar sha256sum awk; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command missing: $cmd"
  done
fi

if [ "$PLATFORM" = "ubuntu20" ]; then
  warn "Ubuntu 20.04 is no longer in Docker's current package-support list. Do not let this installer replace or upgrade the existing Docker Engine automatically."
else
  warn "CentOS 7 is EOL and is not supported by current Docker CE packages. This project deliberately reuses the existing Docker Engine and does not replace it."
fi

echo "[OK] preflight completed"
