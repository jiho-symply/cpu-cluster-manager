#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "[ERROR] $*" >&2; exit 1; }

RENTER=node/rent-image/renter-account.sh
UI=manager/app/templates/index.html
MAIN=manager/app/main.py
SSH_CLIENT=manager/app/ssh_client.py
ADMIN=node/cluster-node-admin
SSH_WRAPPER=node/cluster-node-ssh
SUDOERS=node/sudoers/cpu-cluster-manager

echo '== renter password generator =='
PASSWORD_FN="$(sed -n '/^new_password() {/,/^}/p' "$RENTER")"
[ -n "$PASSWORD_FN" ] || fail 'new_password() not found'
eval "$PASSWORD_FN"
for _ in $(seq 1 250); do
  password="$(new_password)"
  [ "${#password}" -eq 8 ] || fail "password length is not 8: $password"
  [[ "$password" =~ ^[A-Za-z0-9]{8}$ ]] || fail "password contains a non-alphanumeric character: $password"
  [[ "$password" =~ [A-Z] ]] || fail "password has no uppercase character: $password"
  [[ "$password" =~ [a-z] ]] || fail "password has no lowercase character: $password"
  [[ "$password" =~ [0-9] ]] || fail "password has no digit: $password"
done
echo '[OK] 250 generated passwords satisfy 8-char A-Z/a-z/0-9 policy'

echo '== structured reset credential response =='
grep -Fq 'def parse_reset_credential' "$MAIN" || fail 'backend credential parser missing'
grep -Fq 'payload["credential"] = credential' "$MAIN" || fail 'reset-password API must return structured credential data'
echo '[OK] reset-password returns structured one-time credential'

echo '== browser-only credential persistence =='
grep -Fq 'const credentialCache=new Map();' "$UI" || fail 'browser in-memory credential cache missing'
grep -Fq 'data-copy-password=' "$UI" || fail 'password Copy button missing'
grep -Fq 'credentialCache.set(credentialKey(cluster,node),credential)' "$UI" || fail 'reset password is not retained in the in-memory node cache'
if grep -Eq 'localStorage|sessionStorage|indexedDB' "$UI"; then
  fail 'temporary passwords must not persist beyond the current browser page lifetime'
fi
grep -Fq 'kept until browser page reload' "$UI" || fail 'credential lifetime hint missing'
echo '[OK] credentials persist across UI refreshes but not browser page reloads'

echo '== action grouping =='
grep -Fq 'class="action-safe"' "$UI" || fail 'low-risk action group missing'
grep -Fq 'class="action-danger"' "$UI" || fail 'high-risk action group missing'
grep -Fq "'start','Start'" "$UI" || fail 'Start action missing'
grep -Fq "'stop','Stop'" "$UI" || fail 'Stop action missing'
grep -Fq "'restart','Restart'" "$UI" || fail 'Restart action missing'
grep -Fq "'logs','Logs'" "$UI" || fail 'Logs action missing'
grep -Fq "'reset-password','Reset PW',true" "$UI" || fail 'Reset PW must be in the dangerous group'
grep -Fq "'recreate','Recreate',true" "$UI" || fail 'Recreate must be in the dangerous group'
grep -Fq "'reboot','Reboot host',true" "$UI" || fail 'Reboot host must be in the dangerous group'
echo '[OK] low-risk actions are left; disruptive actions are right'

echo '== individual host reboot only =='
grep -Fq 'reboot_host()' "$ADMIN" || fail 'compute reboot implementation missing'
grep -Fq 'systemctl reboot --no-block' "$ADMIN" || fail 'compute reboot must use systemd reboot'
for f in "$SSH_WRAPPER" "$SUDOERS" "$SSH_CLIENT"; do
  grep -Fq 'reboot' "$f" || fail "reboot control path missing from $f"
done
grep -Fq '"reboot"}' "$MAIN" || fail 'individual-node API must expose reboot'
if grep -Fq 'Power off host' "$UI"; then
  fail 'individual Power off host control must not be exposed in the UI'
fi
# Poweroff is intentionally retained underneath for cluster-wide staged shutdown.
grep -Fq 'poweroff_and_wait' "$SSH_CLIENT" || fail 'cluster-wide safe poweroff path must remain available'
grep -Fq 'docker stop -t 30' "$ADMIN" || fail 'cluster-wide shutdown must still stop rent-node before compute poweroff'
echo '[OK] individual host control exposes reboot; cluster-wide shutdown retains internal poweroff'

echo '[OK] credential/UI policy checks passed'
