#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="/src/rent/image"
# shellcheck disable=SC1091
source /src/rent/image/rent.env

BASE="${BASE:-/src/rent}"
IMAGE_NAME="${IMAGE_NAME:-rent-ubuntu:22.04}"
CONTAINER_NAME="${CONTAINER_NAME:-rent-node}"
RENT_TREE_SHA="${RENT_TREE_SHA:-unknown}"

usage() {
  cat <<USAGE
Usage:
  /src/rent/image/rentctl.sh help
  /src/rent/image/rentctl.sh build
  /src/rent/image/rentctl.sh setup
  /src/rent/image/rentctl.sh reset
  /src/rent/image/rentctl.sh stop
  /src/rent/image/rentctl.sh restart
  /src/rent/image/rentctl.sh recreate
  /src/rent/image/rentctl.sh status
  /src/rent/image/rentctl.sh reset-password

Functions:
  help            : 사용 가능한 기능과 역할 출력
  build           : Git-managed source로 Docker 이미지 빌드
  setup           : /src/rent 디렉토리 생성 + auth DB 초기화 + 컨테이너 실행 + 기본 대여 계정 생성
  reset           : 컨테이너 중지/삭제 + /src/rent 데이터 초기화 + auth DB 초기화 + 기본 대여 계정 재생성
  stop            : 컨테이너 중지
  restart         : 컨테이너 재시작
  recreate        : 기존 컨테이너 삭제 후 현재 이미지로 재생성 (기존 /src/rent 데이터 유지)
  status          : 컨테이너 실행 상태 + 저장소 디렉토리 상태 + 대여 계정 상태 확인
  reset-password  : 기본 대여 계정 비밀번호를 새로운 random temporary password로 재설정
USAGE
}

ensure_dirs() {
  sudo mkdir -p "${BASE}/image" "${BASE}/auth" "${BASE}/home" "${BASE}/ssh" "${BASE}/work" "${BASE}/logs"
  sudo chown root:root "${BASE}/auth" "${BASE}/ssh"
  sudo chmod 700 "${BASE}/auth" "${BASE}/ssh"
  sudo chmod 755 "${BASE}" "${BASE}/home" "${BASE}/work" "${BASE}/logs"
}

wait_ready() {
  local i
  for i in $(seq 1 60); do
    if sudo docker exec -u 0 "${CONTAINER_NAME}" test -f /run/rent-ready 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "[ERROR] container is not ready: ${CONTAINER_NAME}" >&2
  exit 1
}

print_dir_sizes() {
  local d size
  printf "%-8s %-8s %s\n" "NAME" "SIZE" "PATH"
  for d in auth home ssh work logs; do
    size="$(sudo du -sh "${BASE}/${d}" 2>/dev/null | awk '{print $1}')"
    [ -n "${size}" ] || size="-"
    printf "%-8s %-8s %s\n" "${d}" "${size}" "${BASE}/${d}"
  done
}

cmd_build() {
  sudo docker build \
    --label "io.cpu-cluster-manager.rent-tree=${RENT_TREE_SHA}" \
    -t "${IMAGE_NAME}" \
    "${SCRIPT_DIR}"
}

cmd_setup() {
  ensure_dirs
  sudo /src/rent/image/init-auth-db.sh "${IMAGE_NAME}"
  sudo /src/rent/image/run-rent-container.sh "${IMAGE_NAME}" "${CONTAINER_NAME}"
  wait_ready
  sudo /src/rent/image/renter-account.sh create
}

cmd_reset() {
  sudo docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

  sudo rm -rf \
    "${BASE}/auth"/* \
    "${BASE}/home"/* \
    "${BASE}/ssh"/* \
    "${BASE}/work"/* \
    "${BASE}/logs"/*

  ensure_dirs
  sudo /src/rent/image/init-auth-db.sh "${IMAGE_NAME}"
  sudo /src/rent/image/run-rent-container.sh "${IMAGE_NAME}" "${CONTAINER_NAME}"
  wait_ready
  sudo /src/rent/image/renter-account.sh create
}

cmd_stop() {
  sudo docker stop "${CONTAINER_NAME}"
}

cmd_restart() {
  sudo docker restart "${CONTAINER_NAME}"
}

cmd_recreate() {
  sudo docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  sudo /src/rent/image/run-rent-container.sh "${IMAGE_NAME}" "${CONTAINER_NAME}"
  wait_ready
}

cmd_status() {
  echo "=== docker ps ==="
  sudo docker ps -a --filter "name=${CONTAINER_NAME}"
  echo

  echo "=== image source revision ==="
  sudo docker image inspect "$IMAGE_NAME" \
    --format 'rent-tree={{ index .Config.Labels "io.cpu-cluster-manager.rent-tree" }}' 2>/dev/null || true
  echo

  echo "=== storage (recursive size) ==="
  print_dir_sizes
  echo

  echo "=== storage (detail) ==="
  sudo ls -ld \
    "${BASE}" \
    "${BASE}/auth" \
    "${BASE}/home" \
    "${BASE}/ssh" \
    "${BASE}/work" \
    "${BASE}/logs"
  echo

  echo "=== renter account ==="
  sudo /src/rent/image/renter-account.sh status || true
}

cmd_reset_password() {
  wait_ready
  sudo /src/rent/image/renter-account.sh reset-password
}

ACTION="${1:-help}"
case "${ACTION}" in
  help|-h|--help)  usage ;;
  build)           cmd_build ;;
  setup)           cmd_setup ;;
  reset)           cmd_reset ;;
  stop)            cmd_stop ;;
  restart)         cmd_restart ;;
  recreate)        cmd_recreate ;;
  status)          cmd_status ;;
  reset-password)  cmd_reset_password ;;
  *) usage; exit 1 ;;
esac
