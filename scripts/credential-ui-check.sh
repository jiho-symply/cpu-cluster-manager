#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "[ERROR] $*" >&2; exit 1; }

RENTER=node/rent-image/renter-account.sh
RENTCTL=node/rent-image/rentctl.sh
UI=manager/app/templates/index.html
MAIN=manager/app/main.py
LIVE=manager/app/live_metrics.py
DASH=monitoring/grafana/dashboards/cluster-monitoring.json
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

echo '== reset credential responses =='
grep -Fq 'def parse_reset_credential' "$MAIN" || fail 'backend credential parser missing'
grep -Fq 'if action in {"reset-password", "reset"}' "$MAIN" || fail 'password reset and full reset must both return credentials'
grep -Fq 'payload["credential"] = credential' "$MAIN" || fail 'credential response payload missing'
echo '[OK] reset-password and full reset return structured credentials'

echo '== full reset control path =='
for f in "$ADMIN" "$SSH_WRAPPER" "$SUDOERS" "$SSH_CLIENT" "$MAIN"; do
  grep -Fq 'reset' "$f" || fail "full reset control path missing from $f"
done
grep -Fq 'clear_persistent_dir "${BASE}/home"' "$RENTCTL" || fail 'full reset must clear renter home'
grep -Fq 'clear_persistent_dir "${BASE}/work"' "$RENTCTL" || fail 'full reset must clear renter workspace'
grep -Fq 'clear_persistent_dir "${BASE}/auth"' "$RENTCTL" || fail 'full reset must clear auth state'
grep -Fq 'clear_persistent_dir "${BASE}/ssh"' "$RENTCTL" || fail 'full reset must clear SSH host-key state'
grep -Fq 'find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' "$RENTCTL" || fail 'full reset must remove hidden entries as well as normal files'
echo '[OK] full reset clears all persistent renter contents including dotfiles'

echo '== browser-only credential persistence =='
grep -Fq 'const credentialCache=new Map();' "$UI" || fail 'browser in-memory credential cache missing'
grep -Fq 'data-copy-password=' "$UI" || fail 'password Copy button missing'
grep -Fq 'credentialCache.set(credentialKey(cluster,node),credential)' "$UI" || fail 'reset credential is not retained in the in-memory node cache'
if grep -Eq 'localStorage|sessionStorage|indexedDB' "$UI"; then
  fail 'temporary passwords must not persist beyond the current browser page lifetime'
fi
grep -Fq 'kept until browser page reload' "$UI" || fail 'credential lifetime hint missing'
echo '[OK] credentials persist across UI refreshes but not browser page reloads'

echo '== control table resource snapshot =='
for field in cpu_percent memory_percent disk_percent; do
  grep -Fq "$field" "$LIVE" || fail "live metric field missing: $field"
  grep -Fq "$field" "$MAIN" || fail "control payload does not expose $field"
  grep -Fq "$field" "$UI" || fail "control table does not render $field"
done
grep -Fq 'cluster_node_cpu_utilization_ratio' "$LIVE" || fail 'CPU control metric must come from Prometheus Hot recording series'
grep -Fq 'cluster_node_memory_utilization_ratio' "$LIVE" || fail 'memory control metric must come from Prometheus Hot recording series'
grep -Fq 'cluster_node_disk_utilization_ratio_max' "$LIVE" || fail 'disk control metric must come from Prometheus Hot recording series'
echo '[OK] control table exposes current CPU/memory/disk percentages'

echo '== reduced action set =='
grep -Fq "'logs','Logs'" "$UI" || fail 'Logs action missing'
grep -Fq "'restart','Restart',false,!running" "$UI" || fail 'Restart must be disabled when the container is not running'
grep -Fq "'reset-password','Reset PW',true,!running" "$UI" || fail 'Reset PW must be disabled when the container is not running'
grep -Fq "'reboot','Reboot host',true" "$UI" || fail 'Reboot host action missing'
grep -Fq "'reset','Full Reset',true" "$UI" || fail 'Full Reset must be the destructive reset action'
for removed in "'start','Start'" "'stop','Stop'" "'recreate','Recreate'"; do
  if grep -Fq "$removed" "$UI"; then fail "removed control button still present: $removed"; fi
done
python3 - "$UI" <<'PY'
import re, sys
text=open(sys.argv[1], encoding='utf-8').read()
safe=re.search(r"const safe=`([^`]+)`;", text)
risky=re.search(r"const risky=`([^`]+)`;", text)
assert safe and risky, 'action groups missing'
assert "'logs','Logs'" in safe.group(1), 'Logs must be the left action'
assert "'restart','Restart'" in risky.group(1), 'Restart must remain available'
assert "'reset-password','Reset PW'" in risky.group(1), 'Reset PW missing'
assert "'reboot','Reboot host'" in risky.group(1), 'Reboot missing'
assert "'reset','Full Reset'" in risky.group(1), 'Full Reset missing'
PY
echo '[OK] Logs is leftmost and Start/Stop/Recreate are removed'

echo '== confirmation modal policy =='
grep -Fq '<dialog id="confirm-dialog">' "$UI" || fail 'shared confirmation modal missing'
grep -Fq 'function requestConfirmation(' "$UI" || fail 'confirmation modal helper missing'
for action in restart reset-password reboot reset; do
  grep -Fq "case '$action':" "$UI" || fail "confirmation definition missing for $action"
done
if grep -Fq 'confirm(' "$UI"; then fail 'browser-native confirm() must not be used'; fi
if grep -Fq 'prompt(' "$UI"; then fail 'browser-native prompt() must not be used'; fi
grep -Fq "if(action==='logs')" "$UI" || fail 'Logs immediate-action exception missing'
grep -Fq 'logsDialog.showModal();' "$UI" || fail 'Logs must open immediately in its dialog'
grep -Fq 'await requestConfirmation(confirmation.title' "$UI" || fail 'node mutations must await confirmation modal'
grep -Fq "'Shutdown all compute nodes'" "$UI" || fail 'cluster compute shutdown must use confirmation modal'
grep -Fq "'Shutdown master'" "$UI" || fail 'master shutdown must use confirmation modal'
echo '[OK] every visible mutating control uses the shared modal; Logs opens immediately'

echo '== flat monitoring node selector =='
grep -Fq 'function monitorEntries()' "$UI" || fail 'flat monitoring node inventory missing'
grep -Fq 'id="monitor-node-select"' "$UI" || fail 'unified monitoring node selector missing'
grep -Fq 'monitorActions.addEventListener(' "$UI" || fail 'monitor node selector handler missing'
if grep -Fq 'monitor-cluster' "$UI"; then fail 'Monitoring must not expose cluster selector buttons'; fi
python3 - "$DASH" <<'PY'
import json, sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
vars=data['templating']['list']
node=next(v for v in vars if v.get('name')=='node')
assert node.get('hide') == 2, node
PY
echo '[OK] monitoring shows one flat node list and hides Grafana-local selector'

echo '== individual host reboot only =='
grep -Fq 'reboot_host()' "$ADMIN" || fail 'compute reboot implementation missing'
grep -Fq 'systemctl reboot --no-block' "$ADMIN" || fail 'compute reboot must use systemd reboot'
for f in "$SSH_WRAPPER" "$SUDOERS" "$SSH_CLIENT"; do
  grep -Fq 'reboot' "$f" || fail "reboot control path missing from $f"
done
grep -Fq '"reboot"' "$MAIN" || fail 'individual-node API must expose reboot'
if grep -Fq 'Power off host' "$UI"; then fail 'individual Power off host control must not be exposed in the UI'; fi
grep -Fq 'poweroff_and_wait' "$SSH_CLIENT" || fail 'cluster-wide safe poweroff path must remain available'
grep -Fq 'docker stop -t 30' "$ADMIN" || fail 'cluster-wide shutdown must still stop rent-node before compute poweroff'
echo '[OK] individual host control exposes reboot; cluster-wide shutdown retains internal poweroff'

echo '[OK] credential/UI policy checks passed'
