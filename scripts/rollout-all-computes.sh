#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="ysadmin"
STATE_DIR="/var/lib/cpu-cluster-manager"
CONFIG="${1:-$STATE_DIR/cluster.local.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "[ERROR] $*" >&2; exit 1; }
get_cfg() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG"; }

[ "$(id -un)" = "$ADMIN_USER" ] || fail "run as $ADMIN_USER without sudo"
[ -f "$CONFIG" ] || fail "cluster config not found: $CONFIG"
if ! git diff --quiet || ! git diff --cached --quiet; then
  git status --short >&2
  fail "tracked local changes exist; refusing full rollout"
fi

CLUSTER="$(get_cfg CLUSTER)"
[ "$CLUSTER" = "cluster1" ] || [ "$CLUSTER" = "cluster2" ] || fail "unsupported CLUSTER=$CLUSTER"
INVENTORY="$ROOT/inventory/${CLUSTER}.nodes"
[ -f "$INVENTORY" ] || fail "inventory not found: $INVENTORY"

ENTRIES=()
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -n "$line" ] || continue
  name="${line%%@*}"
  host="${line#*@}"
  [ "$host" != "$line" ] && [ -n "$name" ] && [ -n "$host" ] || fail "invalid inventory entry: $raw"
  ENTRIES+=("$name@$host")
done < "$INVENTORY"
[ "${#ENTRIES[@]}" -gt 0 ] || fail "empty inventory: $INVENTORY"
NODES_CSV="$(IFS=,; echo "${ENTRIES[*]}")"
EXPECTED_COUNT=6
[ "${#ENTRIES[@]}" -eq "$EXPECTED_COUNT" ] || fail "$CLUSTER inventory must contain $EXPECTED_COUNT computes, found ${#ENTRIES[@]}"

echo "=================================================="
echo "CPU Cluster Manager full rollout: $CLUSTER"
echo "=================================================="
printf '  %s\n' "${ENTRIES[@]}"
echo

echo "[1/8] Preparing current master/source state"
bash "$ROOT/scripts/install-master.sh" "$CONFIG"
bash "$ROOT/scripts/verify-manager-ssh.sh" "$CONFIG"

SOURCE_STATE="$ROOT/.cluster-source-state"
DEPLOY_COMMIT="$(awk -F= '$1=="commit" {print $2; exit}' "$SOURCE_STATE")"
STAMPED_SOURCE_HASH="$(awk -F= '$1=="source_hash" {print $2; exit}' "$SOURCE_STATE")"
[[ "$DEPLOY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source commit stamp"
[[ "$STAMPED_SOURCE_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "invalid source hash stamp"

echo "[2/8] Building immutable release bundle"
bash "$ROOT/scripts/build-release-bundle.sh"
BUNDLE_PATH="$STATE_DIR/releases/ccm-${DEPLOY_COMMIT}.tar"
[ -f "$BUNDLE_PATH" ] || fail "release bundle missing after build: $BUNDLE_PATH"
BUNDLE_SHA256="$(sha256sum "$BUNDLE_PATH" | awk '{print $1}')"
[[ "$BUNDLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid release bundle sha256"
echo "[OK] release transport artifact: $(basename "$BUNDLE_PATH") (${BUNDLE_SHA256:0:12})"

BOOT_DIR="$(mktemp -d /tmp/ccm-rollout.XXXXXX)"
BOOT_KEY="$BOOT_DIR/bootstrap_ed25519"
BOOT_KNOWN_HOSTS="$BOOT_DIR/known_hosts"
RUN_TOKEN="${CLUSTER}-$$-$(date +%s)"
MARKER="ccm-bootstrap-${RUN_TOKEN}"
AUTH_DIR="$HOME/.ssh"
AUTHORIZED_KEYS="$AUTH_DIR/authorized_keys"
BOOTSTRAP_ACTIVE=0
SUDO_PASS=""

cleanup_bootstrap() {
  if [ "$BOOTSTRAP_ACTIVE" -eq 1 ] && [ -f "$AUTHORIZED_KEYS" ]; then
    tmp_auth="$(mktemp "$AUTH_DIR/.authorized_keys.XXXXXX")"
    awk -v marker="$MARKER" 'index($0, marker) == 0 {print}' "$AUTHORIZED_KEYS" > "$tmp_auth"
    chmod 0600 "$tmp_auth"
    mv "$tmp_auth" "$AUTHORIZED_KEYS"
    BOOTSTRAP_ACTIVE=0
    echo "[CLEANUP] removed temporary bootstrap SSH key"
  fi
  SUDO_PASS=""
  unset SUDO_PASS || true
  rm -rf "$BOOT_DIR"
}
trap cleanup_bootstrap EXIT INT TERM

mkdir -p "$AUTH_DIR"
chmod 0700 "$AUTH_DIR"
touch "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"
ssh-keygen -q -t ed25519 -N '' -C "$MARKER" -f "$BOOT_KEY"
cat "$BOOT_KEY.pub" >> "$AUTHORIZED_KEYS"
BOOTSTRAP_ACTIVE=1

ssh_common=(
  -i "$BOOT_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=4
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$BOOT_KNOWN_HOSTS"
)
scp_common=(
  -q
  -i "$BOOT_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=4
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$BOOT_KNOWN_HOSTS"
)

echo "[3/8] Scanning SSH host keys"
: > "$BOOT_KNOWN_HOSTS"
for entry in "${ENTRIES[@]}"; do
  host="${entry#*@}"
  scanned="$(ssh-keyscan -T 5 -t ed25519 "$host" 2>/dev/null || true)"
  [ -n "$scanned" ] || fail "SSH host-key scan failed: $entry"
  printf '%s\n' "$scanned" >> "$BOOT_KNOWN_HOSTS"
done
chmod 0600 "$BOOT_KNOWN_HOSTS"

echo "[4/8] Verifying hostname <-> private-IP inventory"
for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  host="${entry#*@}"
  actual="$(ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" 'hostname -s' 2>/dev/null || true)"
  [ "$actual" = "$name" ] || fail "inventory mismatch: expected $name at $host, remote hostname=${actual:--}"
  echo "[OK] $name = $host"
done

echo "[5/8] Preflighting sudo on every compute"
NEED_PASSWORD=0
for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  host="${entry#*@}"
  sudo_probe="$(ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" 'sudo -n true' 2>&1 || true)"
  if grep -Eqi 'must have a tty|terminal is required|no tty present' <<<"$sudo_probe"; then
    fail "sudo on $name ($host) requires a TTY; refusing password transport that could echo credentials"
  fi
  if ! ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" 'sudo -n true' >/dev/null 2>&1; then
    NEED_PASSWORD=1
  fi
done

if [ "$NEED_PASSWORD" -eq 1 ]; then
  printf 'ysadmin sudo password (used in memory only): ' >&2
  IFS= read -r -s SUDO_PASS
  echo >&2
  [ -n "$SUDO_PASS" ] || fail "empty sudo password"
fi

for entry in "${ENTRIES[@]}"; do
  name="${entry%%@*}"
  host="${entry#*@}"
  if ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" 'sudo -n true' >/dev/null 2>&1; then
    :
  else
    if ! printf '%s\n' "$SUDO_PASS" | ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" "sudo -S -p '' true" >/dev/null 2>&1; then
      fail "sudo authentication preflight failed on $name ($host); no compute was modified"
    fi
  fi
done
echo "[OK] sudo preflight passed on all ${#ENTRIES[@]} computes"

run_remote_install() {
  local entry="$1" name host log rc remote_bundle remote_root
  name="${entry%%@*}"
  host="${entry#*@}"
  log="$BOOT_DIR/${name}.log"
  remote_bundle="/tmp/ccm-release-${RUN_TOKEN}.tar"
  remote_root="/tmp/ccm-release-${RUN_TOKEN}"

  echo "[INSTALL] $name ($host)"
  : > "$log"
  set +e

  ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" "rm -rf '$remote_root' '$remote_bundle' && mkdir -m 700 '$remote_root'" >>"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    scp "${scp_common[@]}" "$BUNDLE_PATH" "$ADMIN_USER@$host:$remote_bundle" >>"$log" 2>&1
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" "set -e; actual=\$(sha256sum '$remote_bundle' | awk '{print \$1}'); [ \"\$actual\" = '$BUNDLE_SHA256' ] || { echo '[ERROR] transported release bundle checksum mismatch' >&2; exit 20; }; tar -xf '$remote_bundle' -C '$remote_root'; [ -f '$remote_root/.release-source-manifest.sha256' ] || { echo '[ERROR] release per-file manifest missing after extraction' >&2; exit 21; }; if ! (cd '$remote_root' && sha256sum -c .release-source-manifest.sha256 >/dev/null 2>&1); then echo '[ERROR] extracted release file checksum mismatch' >&2; (cd '$remote_root' && sha256sum -c .release-source-manifest.sha256 2>&1 | grep -E 'FAILED|No such file|WARNING' || true) >&2; exit 21; fi; actual_source=\$(sha256sum '$remote_root/.release-source-manifest.sha256' | awk '{print \$1}'); [ \"\$actual_source\" = '$STAMPED_SOURCE_HASH' ] || { echo \"[ERROR] extracted release manifest hash mismatch: expected=$STAMPED_SOURCE_HASH actual=\$actual_source\" >&2; exit 21; }; actual_commit=\$(awk -F= '\$1==\"commit\" {print \$2; exit}' '$remote_root/.cluster-source-state'); [ \"\$actual_commit\" = '$DEPLOY_COMMIT' ] || { echo '[ERROR] extracted release commit mismatch' >&2; exit 22; }; echo '[OK] immutable release verified locally'" >>"$log" 2>&1
    rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    if ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" 'sudo -n true' >/dev/null 2>&1; then
      ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" \
        "sudo -n bash '$remote_root/node/install-node.sh' '$remote_root/.cluster-manager.pub' && bash '$remote_root/node/verify-node.sh'" \
        >>"$log" 2>&1
      rc=$?
    else
      printf '%s\n' "$SUDO_PASS" | ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" \
        "sudo -S -p '' bash '$remote_root/node/install-node.sh' '$remote_root/.cluster-manager.pub' && bash '$remote_root/node/verify-node.sh'" \
        >>"$log" 2>&1
      rc=$?
    fi
  fi

  ssh -T "${ssh_common[@]}" "$ADMIN_USER@$host" "rm -rf '$remote_root' '$remote_bundle'" >>"$log" 2>&1 || true
  set -e

  if [ "$rc" -ne 0 ]; then
    echo "[FAIL] $name ($host)" >&2
    cat "$log" >&2
    return "$rc"
  fi
  echo "[OK] $name installed and verified from immutable release"
  grep -E '^\[CREDENTIAL\]' "$log" || true
}

# Compute installs remain serialized because every node updates the same
# NFS-backed /home/ysadmin/authorized_keys file. Deployment source itself is
# no longer executed from NFS: one immutable tar is copied over SSH, verified,
# extracted to local /tmp, and executed only from that local snapshot.
echo "[6/8] Installing/updating all computes sequentially"
for entry in "${ENTRIES[@]}"; do
  run_remote_install "$entry" || fail "compute rollout failed; master NODES was not expanded"
done

cleanup_bootstrap
trap - EXIT INT TERM

echo "[7/8] Expanding master NODES to the full validated inventory"
BACKUP="$CONFIG.pre-full-rollout-$(date +%Y%m%d-%H%M%S)"
cp -p "$CONFIG" "$BACKUP"
tmp_cfg="$(mktemp "$STATE_DIR/.cluster.local.env.XXXXXX")"
awk -F= -v value="$NODES_CSV" '
  $1=="NODES" {print "NODES=" value; found=1; next}
  {print}
  END {if (!found) print "NODES=" value}
' "$CONFIG" > "$tmp_cfg"
chmod 0600 "$tmp_cfg"
mv "$tmp_cfg" "$CONFIG"
echo "[OK] full inventory written to $CONFIG"
echo "[BACKUP] previous config: $BACKUP"

bash "$ROOT/scripts/install-master.sh" "$CONFIG"
bash "$ROOT/scripts/verify-manager-ssh.sh" "$CONFIG"

echo "[8/8] End-to-end verification"
bash "$ROOT/scripts/verify-cluster.sh" "$CONFIG"

echo
echo "=================================================="
echo "[OK] FULL ROLLOUT COMPLETE: $CLUSTER"
echo "[OK] compute nodes: ${#ENTRIES[@]}"
echo "[OK] NODES=$NODES_CSV"
echo "=================================================="
