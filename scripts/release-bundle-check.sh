#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
cleanup() {
  rm -f "$ROOT/.cluster-source-state" "$ROOT/.cluster-manager.pub"
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cat > "$TMP/cluster.env" <<'EOF'
CLUSTER=cluster1
EOF
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICIBuildReleaseBundleCheckOnly000000 ci-release-test' > "$ROOT/.cluster-manager.pub"

# Source identity must be independent of caller locale.
HASH_C="$(LC_ALL=C bash scripts/source-hash.sh)"
HASH_UTF8="$(LC_ALL=C.UTF-8 bash scripts/source-hash.sh 2>/dev/null || LC_ALL=C bash scripts/source-hash.sh)"
[ "$HASH_C" = "$HASH_UTF8" ] || { echo '[ERROR] source hash varies by locale' >&2; exit 1; }

bash scripts/write-source-state.sh "$TMP/cluster.env" >/dev/null
COMMIT="$(git rev-parse HEAD)"
EXPECTED_SOURCE_HASH="$(awk -F= '$1=="source_hash" {print $2; exit}' .cluster-source-state)"

ADMIN_USER="$(id -un)" STATE_DIR="$TMP/state" bash scripts/build-release-bundle.sh >/dev/null
BUNDLE="$TMP/state/releases/ccm-${COMMIT}.tar"
SUM="$BUNDLE.sha256"
[ -f "$BUNDLE" ] || { echo '[ERROR] release bundle was not created' >&2; exit 1; }
[ -f "$SUM" ] || { echo '[ERROR] release bundle checksum file was not created' >&2; exit 1; }
(
  cd "$(dirname "$BUNDLE")"
  sha256sum -c "$(basename "$SUM")" >/dev/null
)

mkdir -p "$TMP/extracted"
tar -xf "$BUNDLE" -C "$TMP/extracted"
[ -f "$TMP/extracted/.cluster-source-state" ] || { echo '[ERROR] source stamp missing from release bundle' >&2; exit 1; }
[ -f "$TMP/extracted/.cluster-manager.pub" ] || { echo '[ERROR] manager public key missing from release bundle' >&2; exit 1; }
[ -f "$TMP/extracted/.release-source-manifest.sha256" ] || { echo '[ERROR] canonical source manifest missing from release bundle' >&2; exit 1; }
BUNDLED_COMMIT="$(awk -F= '$1=="commit" {print $2; exit}' "$TMP/extracted/.cluster-source-state")"
[ "$BUNDLED_COMMIT" = "$COMMIT" ] || { echo '[ERROR] bundled commit mismatch' >&2; exit 1; }
(
  cd "$TMP/extracted"
  sha256sum -c .release-source-manifest.sha256 >/dev/null
)
MANIFEST_HASH="$(sha256sum "$TMP/extracted/.release-source-manifest.sha256" | awk '{print $1}')"
[ "$MANIFEST_HASH" = "$EXPECTED_SOURCE_HASH" ] || { echo '[ERROR] bundled manifest identity mismatch' >&2; exit 1; }
ACTUAL_SOURCE_HASH="$(cd "$TMP/extracted" && bash scripts/source-hash.sh)"
[ "$ACTUAL_SOURCE_HASH" = "$EXPECTED_SOURCE_HASH" ] || { echo '[ERROR] extracted source hash mismatch' >&2; exit 1; }
cmp -s "$ROOT/.cluster-manager.pub" "$TMP/extracted/.cluster-manager.pub" || { echo '[ERROR] bundled manager public key mismatch' >&2; exit 1; }

echo '[OK] immutable release bundle build/extract/per-file-checksum path'
