#!/usr/bin/env bash
set -euo pipefail

MIN_DOCKER_VERSION="20.10.10"
MIN_DOCKER_API="1.41"
TARGET_DOCKER_VERSION="20.10.17"
TARGET_DOCKER_RPM="20.10.17-3.el7"
TARGET_CONTAINERD_RPM="1.6.6-3.1.el7"
DOCKER_RPM_BASE="https://download.docker.com/linux/centos/7/x86_64/stable/Packages"
DOCKER_GPG_URL="https://download.docker.com/linux/centos/gpg"
CENTOS_EXTRAS_BASE_PRIMARY="https://vault.centos.org/7.9.2009/extras/x86_64/Packages"
CENTOS_EXTRAS_BASE_FALLBACK="https://mirrors.aliyun.com/centos/7.9.2009/extras/x86_64/Packages"
CENTOS_GPG_KEY="/etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7"

fail() { echo "[ERROR] $*" >&2; exit 1; }
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}
verify_rpm_signature() {
  local path="$1"
  local out
  out="$(rpm -K "$path" 2>&1)" || {
    echo "$out" >&2
    fail "RPM signature verification failed: $(basename "$path")"
  }
  if ! grep -Eq '(^|[[:space:]])OK$|digests signatures OK' <<<"$out"; then
    echo "$out" >&2
    fail "RPM signature verification failed: $(basename "$path")"
  fi
}
download_centos_extra() {
  local rpm_file="$1"
  local base
  for base in "$CENTOS_EXTRAS_BASE_PRIMARY" "$CENTOS_EXTRAS_BASE_FALLBACK"; do
    echo "[INFO] downloading $rpm_file from $base"
    if curl -fL --retry 3 --connect-timeout 10 --max-time 120 \
      "$base/$rpm_file" -o "$TMP/$rpm_file"; then
      return 0
    fi
    rm -f "$TMP/$rpm_file"
  done
  fail "cannot download required CentOS 7 Extras RPM: $rpm_file"
}

[ "$(id -u)" -eq 0 ] || fail "ensure-compute-docker.sh must run as root"
[ -r /etc/os-release ] || fail "/etc/os-release not found"
# shellcheck disable=SC1091
. /etc/os-release

command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

CURRENT_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
CURRENT_API="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
[ -n "$CURRENT_VERSION" ] || fail "cannot determine Docker Engine version"
[ -n "$CURRENT_API" ] || fail "cannot determine Docker API version"

if version_ge "$CURRENT_VERSION" "$MIN_DOCKER_VERSION" && version_ge "$CURRENT_API" "$MIN_DOCKER_API"; then
  echo "[KEEP] Docker baseline satisfied: Engine $CURRENT_VERSION / API $CURRENT_API"
  exit 0
fi

echo "[WARN] legacy Docker detected: Engine $CURRENT_VERSION / API $CURRENT_API"
echo "[INFO] required baseline: Engine >= $MIN_DOCKER_VERSION / API >= $MIN_DOCKER_API"

case "${ID:-}:${VERSION_ID:-}" in
  centos:7|centos:7.*) ;;
  *) fail "automatic Docker repair is intentionally limited to CentOS 7 computes" ;;
esac

command -v rpm >/dev/null 2>&1 || fail "rpm is required"
command -v yum >/dev/null 2>&1 || fail "yum is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

if ! rpm -q docker-ce >/dev/null 2>&1; then
  echo "[ERROR] legacy engine is not installed as docker-ce; refusing package-family conversion" >&2
  rpm -qa | grep -E '^(docker|containerd)' >&2 || true
  exit 2
fi

ROOT_BEFORE="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[ -n "$ROOT_BEFORE" ] || ROOT_BEFORE="/var/lib/docker"
RENT_ID_BEFORE="$(docker inspect -f '{{.Id}}' rent-node 2>/dev/null || true)"
RENT_RUNNING_BEFORE="$(docker inspect -f '{{.State.Running}}' rent-node 2>/dev/null || echo false)"

echo "[INFO] upgrading CentOS 7 Docker CE in place to $TARGET_DOCKER_VERSION"
echo "[INFO] Docker root preserved: $ROOT_BEFORE"
if [ -n "$RENT_ID_BEFORE" ]; then
  echo "[INFO] existing rent-node will be preserved (container id: ${RENT_ID_BEFORE:0:12})"
fi

TMP="$(mktemp -d /var/tmp/ccm-docker-upgrade.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Docker CE 20.10.17's EL7 RPM metadata requires docker-ce-rootless-extras.
# Although this cluster uses the normal rootful daemon, RPM dependency closure
# must still be complete. Its two EL7 dependencies are pulled from the archived
# CentOS 7 Extras set, plus fuse3-libs required by fuse-overlayfs. Everything is
# pinned and installed in one local transaction; no retired CentOS yum repo is
# enabled and --nodeps/--skip-broken are intentionally forbidden.
DOCKER_RPMS=(
  "containerd.io-${TARGET_CONTAINERD_RPM}.x86_64.rpm"
  "docker-ce-cli-${TARGET_DOCKER_RPM}.x86_64.rpm"
  "docker-ce-rootless-extras-${TARGET_DOCKER_RPM}.x86_64.rpm"
  "docker-ce-${TARGET_DOCKER_RPM}.x86_64.rpm"
)
CENTOS_EXTRA_RPMS=(
  "fuse3-libs-3.6.1-4.el7.x86_64.rpm"
  "fuse-overlayfs-0.7.2-6.el7_8.x86_64.rpm"
  "slirp4netns-0.4.3-4.el7_8.x86_64.rpm"
)

for rpm_file in "${DOCKER_RPMS[@]}"; do
  echo "[INFO] downloading $rpm_file"
  curl -fL --retry 5 --connect-timeout 10 --max-time 180 \
    "$DOCKER_RPM_BASE/$rpm_file" -o "$TMP/$rpm_file"
done
for rpm_file in "${CENTOS_EXTRA_RPMS[@]}"; do
  download_centos_extra "$rpm_file"
done

# Verify Docker packages against Docker's signing key and CentOS Extras packages
# against the CentOS 7 key shipped with the host OS.
echo "[INFO] importing Docker RPM signing key"
curl -fL --retry 5 --connect-timeout 10 --max-time 60 "$DOCKER_GPG_URL" -o "$TMP/docker.gpg"
rpm --import "$TMP/docker.gpg"
[ -r "$CENTOS_GPG_KEY" ] || fail "CentOS 7 RPM signing key missing: $CENTOS_GPG_KEY"
rpm --import "$CENTOS_GPG_KEY"

for rpm_file in "${DOCKER_RPMS[@]}"; do
  verify_rpm_signature "$TMP/$rpm_file"
done
for rpm_file in "${CENTOS_EXTRA_RPMS[@]}"; do
  verify_rpm_signature "$TMP/$rpm_file"
done

# yum resolves the complete transaction before changing Docker. Pre-existing
# unrelated rpmdb inconsistencies may be reported by yum check, but they do not
# enter this transaction unless they are actual dependencies of these packages.
echo "[INFO] validating/installing pinned Docker dependency transaction"
LOCAL_RPMS=()
for rpm_file in "${CENTOS_EXTRA_RPMS[@]}" "${DOCKER_RPMS[@]}"; do
  LOCAL_RPMS+=("$TMP/$rpm_file")
done
yum -y --disablerepo='*' localinstall "${LOCAL_RPMS[@]}"

systemctl daemon-reload
systemctl enable docker.service >/dev/null
systemctl restart docker.service

for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 1
done
docker info >/dev/null 2>&1 || fail "Docker daemon did not recover after package upgrade"

NEW_VERSION="$(docker version --format '{{.Server.Version}}')"
NEW_API="$(docker version --format '{{.Server.APIVersion}}')"
version_ge "$NEW_VERSION" "$MIN_DOCKER_VERSION" || fail "Docker upgrade incomplete: Engine $NEW_VERSION"
version_ge "$NEW_API" "$MIN_DOCKER_API" || fail "Docker upgrade incomplete: API $NEW_API"

ROOT_AFTER="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[ "$ROOT_AFTER" = "$ROOT_BEFORE" ] || fail "Docker root changed unexpectedly: $ROOT_BEFORE -> $ROOT_AFTER"

if [ -n "$RENT_ID_BEFORE" ]; then
  RENT_ID_AFTER="$(docker inspect -f '{{.Id}}' rent-node 2>/dev/null || true)"
  [ "$RENT_ID_AFTER" = "$RENT_ID_BEFORE" ] || fail "existing rent-node disappeared or changed during Docker upgrade"
  if [ "$RENT_RUNNING_BEFORE" = "true" ] && [ "$(docker inspect -f '{{.State.Running}}' rent-node 2>/dev/null || echo false)" != "true" ]; then
    echo "[INFO] restarting previously-running rent-node after Docker upgrade"
    docker start rent-node >/dev/null
  fi
fi

echo "[OK] Docker repaired in place: Engine $NEW_VERSION / API $NEW_API"
[ -z "$RENT_ID_BEFORE" ] || echo "[OK] existing rent-node container id preserved: ${RENT_ID_BEFORE:0:12}"
