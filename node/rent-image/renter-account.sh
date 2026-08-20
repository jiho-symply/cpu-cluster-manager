#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="/src/rent/image"
if [ -f "${SCRIPT_DIR}/rent.env" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/rent.env"
fi

CONTAINER_NAME="${CONTAINER_NAME:-rent-node}"
BASE_UID="${BASE_UID:-20000}"

usage() {
  cat <<USAGE
Usage:
  $0 create
  $0 reset-password
  $0 reset-all
  $0 delete
  $0 status
  $0 list
USAGE
}

wait_ready() {
  local i
  for i in $(seq 1 60); do
    if docker exec -u 0 "${CONTAINER_NAME}" test -f /run/rent-ready 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "[ERROR] container is not ready: ${CONTAINER_NAME}" >&2
  exit 1
}

detect_ip() {
  if [ -n "${HOST_IP:-}" ]; then
    echo "${HOST_IP}"
    return
  fi

  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"

  if [ -z "${ip}" ]; then
    ip="$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^172\.17\.' | head -n1)"
  fi

  if [ -z "${ip}" ]; then
    echo "failed to detect host ip" >&2
    exit 1
  fi

  echo "${ip}"
}

build_account_name() {
  if [ -n "${ACCOUNT_NAME:-}" ]; then
    echo "${ACCOUNT_NAME}"
    return
  fi
  local ip last
  ip="$(detect_ip)"
  last="${ip##*.}"
  printf 'engcluster%03d\n' "${last}"
}

build_account_uid() {
  local ip last
  ip="$(detect_ip)"
  last="${ip##*.}"
  echo $((BASE_UID + last))
}

ACCOUNT="$(build_account_name)"
PASSWORD="${ACCOUNT}"
USER_UID="$(build_account_uid)"

cmd_create() {
  wait_ready
  docker exec -u 0 "${CONTAINER_NAME}" bash -lc "
set -e
if ! getent group '${ACCOUNT}' >/dev/null 2>&1; then
  groupadd -g '${USER_UID}' '${ACCOUNT}'
fi
if ! id '${ACCOUNT}' >/dev/null 2>&1; then
  useradd -m -u '${USER_UID}' -g '${ACCOUNT}' -G admin -s /bin/bash '${ACCOUNT}'
fi
echo '${ACCOUNT}:${PASSWORD}' | chpasswd
mkdir -p /home/'${ACCOUNT}'/.ssh
touch /home/'${ACCOUNT}'/.ssh/authorized_keys
chmod 700 /home/'${ACCOUNT}'
chmod 700 /home/'${ACCOUNT}'/.ssh
chmod 600 /home/'${ACCOUNT}'/.ssh/authorized_keys
chown -R '${ACCOUNT}':'${ACCOUNT}' /home/'${ACCOUNT}'
/usr/local/sbin/sync-auth-db
"
  echo "[OK] created or updated account: ${ACCOUNT}"
  echo "initial id/pw: ${ACCOUNT}"
}

cmd_reset_password() {
  wait_ready
  docker exec -u 0 "${CONTAINER_NAME}" bash -lc "
set -e
id '${ACCOUNT}' >/dev/null 2>&1
echo '${ACCOUNT}:${PASSWORD}' | chpasswd
/usr/local/sbin/sync-auth-db
"
  echo "[OK] password reset: ${ACCOUNT} / ${ACCOUNT}"
}

cmd_reset_all() {
  wait_ready
  docker exec -u 0 "${CONTAINER_NAME}" bash -lc "
set -e
id '${ACCOUNT}' >/dev/null 2>&1
pkill -u '${ACCOUNT}' || true
echo '${ACCOUNT}:${PASSWORD}' | chpasswd
rm -f /home/'${ACCOUNT}'/.ssh/authorized_keys
touch /home/'${ACCOUNT}'/.ssh/authorized_keys
chmod 700 /home/'${ACCOUNT}'
chmod 700 /home/'${ACCOUNT}'/.ssh
chmod 600 /home/'${ACCOUNT}'/.ssh/authorized_keys
chown -R '${ACCOUNT}':'${ACCOUNT}' /home/'${ACCOUNT}'
/usr/local/sbin/sync-auth-db
"
  echo "[OK] fully reset account: ${ACCOUNT}"
  echo "password reset to: ${ACCOUNT}"
  echo "authorized_keys cleared"
}

cmd_delete() {
  wait_ready
  docker exec -u 0 "${CONTAINER_NAME}" bash -lc "
set -e
if id '${ACCOUNT}' >/dev/null 2>&1; then
  pkill -u '${ACCOUNT}' || true
  userdel -r '${ACCOUNT}' || true
  groupdel '${ACCOUNT}' || true
  /usr/local/sbin/sync-auth-db
fi
"
  echo "[OK] deleted account: ${ACCOUNT}"
}

cmd_status() {
  wait_ready
  docker exec -u 0 "${CONTAINER_NAME}" bash -lc "
set -e
id '${ACCOUNT}'
getent passwd '${ACCOUNT}'
ls -ld /home/'${ACCOUNT}'
ls -ld /home/'${ACCOUNT}'/.ssh 2>/dev/null || true
"
}

cmd_list() {
  wait_ready
  docker exec -u 0 "${CONTAINER_NAME}" bash -lc "
awk -F: '\$1 ~ /^engcluster[0-9][0-9][0-9]$/ {print \$1, \$3, \$4, \$6}' /etc/passwd
"
}

ACTION="${1:-}"
case "${ACTION}" in
  create)          cmd_create ;;
  reset-password)  cmd_reset_password ;;
  reset-all)       cmd_reset_all ;;
  delete)          cmd_delete ;;
  status)          cmd_status ;;
  list)            cmd_list ;;
  *) usage; exit 1 ;;
esac
