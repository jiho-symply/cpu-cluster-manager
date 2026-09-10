#!/usr/bin/env bash
set -euo pipefail

MIN_DOCKER_VERSION="20.10.10"
MIN_DOCKER_API="1.41"
TARGET_DOCKER_VERSION="20.10.17"
TARGET_DOCKER_RPM="20.10.17-3.el7"
TARGET_CONTAINERD_RPM="1.6.6-3.1.el7"
DOCKER_RPM_BASE="https://download.docker.com/linux/centos/7/x86_64/stable/Packages"
DOCKER_GPG_URL="https://download.docker.com/linux/centos/gpg"

fail() { echo "[ERROR] $*" >&2; exit 1; }
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
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

RPM_FILES=(
  "containerd.io-${TARGET_CONTAINERD_RPM}.x86_64.rpm"
  "docker-ce-cli-${TARGET_DOCKER_RPM}.x86_64.rpm"
  "docker-ce-rootless-extras-${TARGET_DOCKER_RPM}.x86_64.rpm"
  "docker-ce-${TARGET_DOCKER_RPM}.x86_64.rpm"
)

for rpm_file in "${RPM_FILES[@]}"; do
  echo "[INFO] downloading $rpm_file"
  curl -fL --retry 5 --connect-timeout 10 --max-time 180 \
    "$DOCKER_RPM_BASE/$rpm_file" -o "$TMP/$rpm_file"
done

# Import Docker's official signing key, then require every downloaded RPM to
# have a valid signature. The package URLs are pinned to the validated release.
echo "[INFO] importing Docker RPM signing key"
curl -fL --retry 5 --connect-timeout 10 --max-time 60 "$DOCKER_GPG_URL" -o "$TMP/docker.gpg"
rpm --import "$TMP/docker.gpg"
for rpm_file in "${RPM_FILES[@]}"; do
  rpm -K "$TMP/$rpm_file" | grep -Eq 'rsa sha(1|256).*OK|digests signatures OK' \
    || fail "RPM signature verification failed: $rpm_file"
done

# Resolve only against already-installed CentOS dependencies plus the four
# pinned local Docker RPMs. This avoids depending on CentOS 7's retired mirrors.
# yum resolves the full transaction before changing packages, so a missing
# dependency fails before the Docker daemon is touched.
echo "[INFO] validating pinned Docker RPM transaction"
yum -y --disablerepo='*' localinstall "${RPM_FILES[@]/#/$TMP/}"

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
