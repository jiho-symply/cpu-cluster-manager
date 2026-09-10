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
grep -Fq 'bash "$ROOT/scripts/ensure-compute-docker.sh"' node/install-node.sh || fail "compute installer must normalize legacy Docker before preflight"
grep -Fq 'MIN_DOCKER_VERSION="20.10.10"' scripts/preflight.sh || fail "runtime baseline must include clone3-compatible Docker"
grep -Fq 'MIN_DOCKER_API="1.41"' scripts/preflight.sh || fail "runtime API baseline must be 1.41"

echo '[OK] rollout credential transport + legacy Docker repair guards'
