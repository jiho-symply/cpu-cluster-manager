#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "[ERROR] $*" >&2; exit 1; }

bash -n scripts/rollout-all-computes.sh
bash -n scripts/build-release-bundle.sh
bash -n scripts/source-manifest.sh
bash -n scripts/source-hash.sh
bash -n scripts/ensure-compute-docker.sh
bash -n node/install-node.sh
bash -n node/update-node.sh
bash -n scripts/preflight.sh
bash -n scripts/release-bundle-check.sh

if grep -Eq 'ssh[[:space:]]+-tt' scripts/rollout-all-computes.sh; then
  fail "bulk rollout must not allocate a PTY while transporting sudo credentials"
fi
grep -Fq 'ssh -T' scripts/rollout-all-computes.sh || fail "bulk rollout must use a non-PTY SSH channel"
grep -Fq 'used in memory only' scripts/rollout-all-computes.sh || fail "sudo credential handling policy marker missing"
grep -Fq 'unset SUDO_PASS' scripts/rollout-all-computes.sh || fail "sudo credential must be cleared during cleanup"

# Source identity must be canonical across heterogeneous host locales.
grep -Fq 'export LC_ALL=C' scripts/source-manifest.sh || fail "source manifest ordering must force the C locale"
grep -Fq 'bash "$ROOT/scripts/source-manifest.sh"' scripts/source-hash.sh || fail "source hash must derive from the canonical manifest generator"

# Release construction must come from immutable Git objects and embed both the
# runtime metadata and an independent per-file checksum manifest.
grep -Fq 'git archive --format=tar "$COMMIT"' scripts/build-release-bundle.sh || fail "release bundle must be built from Git object database"
grep -Fq 'install -m 0644 "$SOURCE_STATE" "$STAGE/.cluster-source-state"' scripts/build-release-bundle.sh || fail "release bundle must embed source stamp"
grep -Fq 'install -m 0644 "$PUBLISHED_PUBKEY" "$STAGE/.cluster-manager.pub"' scripts/build-release-bundle.sh || fail "release bundle must embed manager public key"
grep -Fq 'bash scripts/source-manifest.sh > .release-source-manifest.sha256' scripts/build-release-bundle.sh || fail "release bundle must embed canonical per-file manifest"
grep -Fq 'sha256sum -c .release-source-manifest.sha256' scripts/build-release-bundle.sh || fail "release build must verify every staged file"
grep -Fq 'MANIFEST_HASH=' scripts/build-release-bundle.sh || fail "release bundle must bind manifest identity to stamped source hash"
grep -Fq 'RELEASE_DIR="$STATE_DIR/releases"' scripts/build-release-bundle.sh || fail "master release artifact must be host-local"

# Compute deployment must transfer one immutable artifact over management SSH,
# verify transport, verify every extracted file, then execute only locally.
grep -Fq 'bash "$ROOT/scripts/build-release-bundle.sh"' scripts/rollout-all-computes.sh || fail "rollout must build immutable release bundle"
grep -Fq 'scp "${scp_common[@]}" "$BUNDLE_PATH"' scripts/rollout-all-computes.sh || fail "rollout must transfer release bundle over SSH"
grep -Fq 'transported release bundle checksum mismatch' scripts/rollout-all-computes.sh || fail "remote bundle sha256 verification missing"
grep -Fq 'release per-file manifest missing after extraction' scripts/rollout-all-computes.sh || fail "remote release manifest presence check missing"
grep -Fq 'extracted release file checksum mismatch' scripts/rollout-all-computes.sh || fail "remote per-file checksum verification missing"
grep -Fq 'extracted release manifest hash mismatch' scripts/rollout-all-computes.sh || fail "remote canonical manifest identity check missing"
grep -Fq 'extracted release commit mismatch' scripts/rollout-all-computes.sh || fail "remote release commit verification missing"
grep -Fq 'remote_root="/tmp/ccm-release-' scripts/rollout-all-computes.sh || fail "compute release must be extracted to local temporary storage"
if grep -Fq 'Waiting for shared source view to converge' scripts/rollout-all-computes.sh; then
  fail "rollout must not depend on mutable NFS source convergence"
fi

grep -Fq 'compute installer source is on network storage' node/install-node.sh || fail "compute installer must reject direct network-source execution"
grep -Fq 'SOURCE_MANIFEST=' node/install-node.sh || fail "compute installer must require the release manifest"
grep -Fq 'local immutable release contains file checksum mismatches' node/install-node.sh || fail "compute installer must verify every immutable release file"
grep -Fq 'local immutable release manifest identity mismatch' node/install-node.sh || fail "compute installer must verify canonical release identity"
HASH_LINE="$(grep -n 'MANIFEST_HASH=' node/install-node.sh | head -n1 | cut -d: -f1)"
DOCKER_LINE="$(grep -n 'bash "$ROOT/scripts/ensure-compute-docker.sh"' node/install-node.sh | head -n1 | cut -d: -f1)"
[ -n "$HASH_LINE" ] && [ -n "$DOCKER_LINE" ] && [ "$HASH_LINE" -lt "$DOCKER_LINE" ] || fail "release integrity must be verified before Docker mutation"
grep -Fq 'direct compute update is disabled' node/update-node.sh || fail "direct NFS-backed compute updater must remain disabled"

# Legacy CentOS 7 Docker repair remains pinned and dependency-complete.
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
if grep -Ev '^[[:space:]]*#' scripts/ensure-compute-docker.sh | grep -Eq -- '--nodeps|--skip-broken'; then
  fail "Docker repair must never bypass RPM dependency integrity"
fi
grep -Fq 'CENTOS_GPG_KEY=' scripts/ensure-compute-docker.sh || fail "CentOS Extras RPMs must be signature verified"
grep -Fq 'verify_rpm_signature' scripts/ensure-compute-docker.sh || fail "pinned Docker repair RPMs must be signature verified"

grep -Fq 'bash "$ROOT/scripts/ensure-compute-docker.sh"' node/install-node.sh || fail "compute installer must normalize legacy Docker before preflight"
grep -Fq 'MIN_DOCKER_VERSION="20.10.10"' scripts/preflight.sh || fail "runtime baseline must include clone3-compatible Docker"
grep -Fq 'MIN_DOCKER_API="1.41"' scripts/preflight.sh || fail "runtime API baseline must be 1.41"

echo '[OK] rollout credential transport + canonical immutable release + Docker repair guards'
