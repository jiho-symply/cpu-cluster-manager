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

need_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "required command missing: $c"
  done
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
need_cmds awk grep sed sort stat systemctl docker getent id install mktemp od tr
id "$ADMIN_USER" >/dev/null 2>&1 || fail "required admin account is missing: $ADMIN_USER"
say "admin account" "$ADMIN_USER"

docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable by the current user"
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
DOCKER_API="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
say "Docker Engine" "${DOCKER_VERSION:-unknown}"
say "Docker API" "${DOCKER_API:-unknown}"
if [ -n "$DOCKER_API" ] && ! version_ge "$DOCKER_API" "$MIN_DOCKER_API"; then
  fail "Docker API $DOCKER_API is older than required baseline $MIN_DOCKER_API"
fi

CGROUP_FS="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
case "$CGROUP_FS" in
  cgroup2fs) CGROUP_MODE="v2" ;;
  tmpfs) CGROUP_MODE="v1/hybrid" ;;
  *) CGROUP_MODE="$CGROUP_FS" ;;
esac
say "cgroup" "$CGROUP_MODE"

SELINUX="disabled"
if command -v getenforce >/dev/null 2>&1; then
  SELINUX="$(getenforce 2>/dev/null || echo unknown)"
fi
say "SELinux" "$SELINUX"

if [ "$PLATFORM" = "centos7" ]; then
  KERNEL="$(uname -r)"
  if [[ "$KERNEL" =~ ^3\.10\.0-([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -lt 366 ]; then
    fail "CentOS/RHEL 7 kernel $KERNEL is older than the validated baseline 3.10.0-366"
  fi
fi

if [ "$ROLE" = "master" ] || [ "$ROLE" = "all" ]; then
  need_cmds curl ssh-keygen ssh-keyscan git
  if docker inspect rent-node >/dev/null 2>&1; then
    fail "rent-node exists on this host; refusing master installation on a compute-like node"
  fi
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin is required on master"
  say "Compose" "$(docker compose version --short 2>/dev/null || docker compose version)"
fi

if [ "$ROLE" = "compute" ] || [ "$ROLE" = "all" ]; then
  need_cmds curl tar sha256sum useradd visudo ss git
  RENT_STATE="$(docker inspect -f '{{.State.Status}}' rent-node 2>/dev/null || echo missing)"
  say "rent-node" "$RENT_STATE"
fi

if [ "$PLATFORM" = "ubuntu20" ]; then
  warn "Ubuntu 20.04 is outside Docker's current package-support list; the validated existing Docker Engine is reused."
else
  warn "CentOS 7 is EOL; the validated existing Docker Engine/kernel are reused and not replaced."
fi

echo "[OK] preflight completed"
