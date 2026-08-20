#!/usr/bin/env bash
set -euo pipefail

rm -f /run/rent-ready

mkdir -p /var/run/sshd
mkdir -p /persist/ssh
mkdir -p /persist/auth
mkdir -p /home /workspace

# SSH host key 영구 보존
if [ ! -f /persist/ssh/ssh_host_rsa_key ] || [ ! -f /persist/ssh/ssh_host_ed25519_key ]; then
  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  ssh-keygen -A
  cp /etc/ssh/ssh_host_rsa_key /persist/ssh/
  cp /etc/ssh/ssh_host_rsa_key.pub /persist/ssh/
  cp /etc/ssh/ssh_host_ed25519_key /persist/ssh/
  cp /etc/ssh/ssh_host_ed25519_key.pub /persist/ssh/
else
  cp /persist/ssh/ssh_host_rsa_key /etc/ssh/
  cp /persist/ssh/ssh_host_rsa_key.pub /etc/ssh/
  cp /persist/ssh/ssh_host_ed25519_key /etc/ssh/
  cp /persist/ssh/ssh_host_ed25519_key.pub /etc/ssh/
  chmod 600 /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_ed25519_key
  chmod 644 /etc/ssh/ssh_host_rsa_key.pub /etc/ssh/ssh_host_ed25519_key.pub
fi

# auth DB 초기화 또는 복원
if [ -f /persist/auth/passwd ] && [ -f /persist/auth/group ] && [ -f /persist/auth/shadow ] && [ -f /persist/auth/gshadow ]; then
  cp /persist/auth/passwd  /etc/passwd
  cp /persist/auth/group   /etc/group
  cp /persist/auth/shadow  /etc/shadow
  cp /persist/auth/gshadow /etc/gshadow
  chmod 644 /etc/passwd /etc/group
  chmod 600 /etc/shadow /etc/gshadow
else
  /usr/local/sbin/sync-auth-db
fi

touch /run/rent-ready
exec /usr/sbin/sshd -D -e
