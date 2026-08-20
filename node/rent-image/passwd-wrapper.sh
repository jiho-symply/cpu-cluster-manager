#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "이 환경에서는 비밀번호를 영구 저장하기 위해 'sudo passwd'를 사용해야 합니다." >&2
  exit 1
fi

if [ $# -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  set -- "${SUDO_USER}"
fi

/usr/bin/passwd "$@"
/usr/local/sbin/sync-auth-db

echo "[OK] password updated and synced"
