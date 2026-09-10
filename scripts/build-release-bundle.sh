#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="${ADMIN_USER:-ysadmin}"
STATE_DIR="${STATE_DIR:-/var/lib/cpu-cluster-manager}"
RELEASE_DIR="$STATE_DIR/releases"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_STATE="$ROOT/.cluster-source-state"
PUBLISHED_PUBKEY="$ROOT/.cluster-manager.pub"

fail() { echo "[ERROR] $*" >&2; exit 1; }
get_state() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$SOURCE_STATE"
}

[ "$(id -un)" = "$ADMIN_USER" ] || fail "run as $ADMIN_USER without sudo"
for cmd in git tar sha256sum awk mktemp install; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command missing: $cmd"
done
[ -f "$SOURCE_STATE" ] || fail "source stamp missing: $SOURCE_STATE"
[ -f "$PUBLISHED_PUBKEY" ] || fail "manager public key missing: $PUBLISHED_PUBKEY"

COMMIT="$(get_state commit)"
SOURCE_HASH="$(get_state source_hash)"
RENT_TREE_SHA="$(get_state rent_tree_sha)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source commit stamp"
[[ "$SOURCE_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "invalid source hash stamp"
[[ "$RENT_TREE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid rent-image tree stamp"

cd "$ROOT"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || fail "source HEAD changed after stamp"
if ! git diff --quiet || ! git diff --cached --quiet; then
  git status --short >&2
  fail "tracked local changes exist; refusing release bundle"
fi
CURRENT_HASH="$(bash "$ROOT/scripts/source-hash.sh")"
[ "$CURRENT_HASH" = "$SOURCE_HASH" ] || fail "master source changed after stamp: stamped=$SOURCE_HASH current=$CURRENT_HASH"

install -d -m 0700 "$STATE_DIR" "$RELEASE_DIR"
BUILD_DIR="$(mktemp -d "$STATE_DIR/.release-build.XXXXXX")"
STAGE="$BUILD_DIR/root"
TMP_BUNDLE="$RELEASE_DIR/.ccm-${COMMIT}.tar.$$.tmp"
TMP_SUM="$RELEASE_DIR/.ccm-${COMMIT}.tar.sha256.$$.tmp"
cleanup() {
  rm -rf "$BUILD_DIR"
  rm -f "$TMP_BUNDLE" "$TMP_SUM"
}
trap cleanup EXIT INT TERM
mkdir -p "$STAGE"

# Build from the immutable Git object database, not from the mutable working
# tree. Runtime-generated deployment metadata is added only after extraction.
git archive --format=tar "$COMMIT" | tar -xf - -C "$STAGE"
install -m 0644 "$SOURCE_STATE" "$STAGE/.cluster-source-state"
install -m 0644 "$PUBLISHED_PUBKEY" "$STAGE/.cluster-manager.pub"

# Embed a canonical per-file checksum manifest. It is outside the source-hash
# file set, so it can independently prove every extracted file byte-for-byte
# and report the exact file if a host ever sees a mismatch.
(
  cd "$STAGE"
  bash scripts/source-manifest.sh > .release-source-manifest.sha256
  sha256sum -c .release-source-manifest.sha256 >/dev/null
)
MANIFEST_HASH="$(sha256sum "$STAGE/.release-source-manifest.sha256" | awk '{print $1}')"
[ "$MANIFEST_HASH" = "$SOURCE_HASH" ] || fail "release manifest hash does not match stamped source: stamped=$SOURCE_HASH manifest=$MANIFEST_HASH"
STAGED_HASH="$(cd "$STAGE" && bash scripts/source-hash.sh)"
[ "$STAGED_HASH" = "$SOURCE_HASH" ] || fail "Git archive does not match stamped source hash: stamped=$SOURCE_HASH archive=$STAGED_HASH"

FINAL_BUNDLE="$RELEASE_DIR/ccm-${COMMIT}.tar"
FINAL_SUM="$FINAL_BUNDLE.sha256"
tar -C "$STAGE" -cf "$TMP_BUNDLE" .
BUNDLE_SHA256="$(sha256sum "$TMP_BUNDLE" | awk '{print $1}')"
chmod 0600 "$TMP_BUNDLE"
printf '%s  %s\n' "$BUNDLE_SHA256" "$(basename "$FINAL_BUNDLE")" > "$TMP_SUM"
chmod 0600 "$TMP_SUM"
mv -f "$TMP_BUNDLE" "$FINAL_BUNDLE"
mv -f "$TMP_SUM" "$FINAL_SUM"
trap - EXIT INT TERM
rm -rf "$BUILD_DIR"

echo "[OK] immutable release bundle: $FINAL_BUNDLE"
echo "[OK] release bundle sha256: $BUNDLE_SHA256"
echo "[OK] release source hash: $SOURCE_HASH"
echo "[OK] release per-file manifest embedded"
