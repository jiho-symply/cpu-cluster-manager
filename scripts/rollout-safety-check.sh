#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "[ERROR] $*" >&2; exit 1; }

bash -n scripts/rollout-all-computes.sh
bash -n scripts/ensure-compute-docker.sh
bash -n node/install-node.sh
bash -n scripts/preflight.sh

if grep -Eq 'ssh[[:space:]]+-tt' scripts/rollout-all-computes.sh; then
  fail "bulk rollout must not allocate a PTY while transporting sudo credentials"
fi
grep -Fq 'ssh -T' scripts/rollout-all-computes.sh || fail "bulk rollout must use a non-PTY SSH channel"
grep -Fq 'used in memory only' scripts/rollout-all-computes.sh || fail "sudo credential handling policy marker missing"
grep -Fq 'unset SUDO_PASS' scripts/rollout-all-computes.sh || fail "sudo credential must be cleared during cleanup"

grep -Fq 'TARGET_DOCKER_VERSION="20.10.17"' scripts/ensure-compute-docker.sh || fail "CentOS 7 repair must pin the validated Docker release"
grep -Fq 'TARGET_CONTAINERD_RPM="1.6.6-3.1.el7"' scripts/ensure-compute-docker.sh || fail "CentOS 7 repair must pin the validated containerd release"
grep -Fq 'rpm -q docker-ce' scripts/ensure-compute-docker.sh || fail "automatic Docker repair must refuse unknown package families"
grep -Fq 'RENT_ID_BEFORE=' scripts/ensure-compute-docker.sh || fail "Docker repair must track existing rent-node identity"
grep -Fq 'RENT_ID_AFTER=' scripts/ensure-compute-docker.sh || fail "Docker repair must verify existing rent-node identity"
grep -Fq 'DockerRootDir' scripts/ensure-compute-docker.sh || fail "Docker repair must preserve Docker root"

grep -Fq 'docker-ce-rootless-extras-${TARGET_DOCKER_RPM}.x86_64.rpm' scripts/ensure-compute-docker.sh || fail "Docker 20.10.17 EL7 dependency closure must include rootless-extras"
grep -Fq 'fuse3-libs-3.6.1-4.el7.x86_64.rpm' scripts/ensure-compute-docker.sh || fail "CentOS 7 Docker repair must pin fuse3-libs"
grep -Fq 'fuse-overlayfs-0.7.2-6.el7_8.x86_64.rpm' scripts/ensure-compute-docker.sh || fail "CentOS 7 Docker repair must pin fuse-overlayfs"
grep -Fq 'slirp4netns-0.4.3-4.el7_8.x86_64.rpm' scripts/ensure-compute-docker.sh || fail "CentOS 7 Docker repair must pin slirp4netns"
grep -Fq -- "--disablerepo='*'" scripts/ensure-compute-docker.sh || fail "CentOS 7 Docker repair must not depend on retired yum repositories"
# Check executable lines only; policy comments intentionally mention the forbidden flags.
if grep -Ev '^[[:space:]]*#' scripts/ensure-compute-docker.sh | grep -Eq -- '--nodeps|--skip-broken'; then
  fail "Docker repair must never bypass RPM dependency integrity"
fi
grep -Fq 'CENTOS_GPG_KEY=' scripts/ensure-compute-docker.sh || fail "CentOS Extras RPMs must be signature verified"
grep -Fq 'verify_rpm_signature' scripts/ensure-compute-docker.sh || fail "pinned Docker repair RPMs must be signature verified"

grep -Fq 'bash "$ROOT/scripts/ensure-compute-docker.sh"' node/install-node.sh || fail "compute installer must normalize legacy Docker before preflight"
grep -Fq 'MIN_DOCKER_VERSION="20.10.10"' scripts/preflight.sh || fail "runtime baseline must include clone3-compatible Docker"
grep -Fq 'MIN_DOCKER_API="1.41"' scripts/preflight.sh || fail "runtime API baseline must be 1.41"

# Shared /home is NFS-backed on computes. Never start a partial rollout while a
# client still has a stale view immediately after the master updates the tree.
grep -Fq '[3b/7] Waiting for shared source view to converge on every compute' scripts/rollout-all-computes.sh || fail "bulk rollout must preflight NFS source convergence"
grep -Fq 'SOURCE_VIEW_RETRIES=15' scripts/rollout-all-computes.sh || fail "bulk rollout source convergence retry window missing"
grep -Fq 'no compute installation started' scripts/rollout-all-computes.sh || fail "source convergence failure must occur before compute installation"
grep -Fq 'SOURCE_HASH_RETRIES=15' node/install-node.sh || fail "compute installer must tolerate transient NFS source cache"
grep -Fq 'after NFS cache convergence window; refusing deployment' node/install-node.sh || fail "compute installer must retain source integrity failure after retries"
if grep -Eq 'drop_caches|write-source-state\.sh' node/install-node.sh; then
  fail "compute installer must not flush system caches or restamp source to bypass integrity checks"
fi

echo '[OK] rollout credential transport + Docker repair + NFS source convergence guards'
