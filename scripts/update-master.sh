#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-/var/lib/cpu-cluster-manager/cluster.local.env}"
cd "$ROOT"

fail() { echo "[ERROR] $*" >&2; exit 1; }

[ "$(id -un)" = "ysadmin" ] || fail "run as ysadmin without sudo"
if ! git diff --quiet || ! git diff --cached --quiet; then
  git status --short >&2
  fail "tracked local changes exist; refusing update"
fi

CURRENT_BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
case "$CURRENT_BRANCH" in
  main|dual-os-support) ;;
  *) fail "unsupported checkout branch: ${CURRENT_BRANCH:-detached}; expected main" ;;
esac

# Older master clones tracked only dual-os-support (--single-branch).
# Register main as an actual tracked ref, not merely a manually fetched
# ref: otherwise --track and --set-upstream-to can reject origin/main.
MAIN_REFSPEC='+refs/heads/main:refs/remotes/origin/main'
if ! git config --get-all remote.origin.fetch | grep -Fxq "$MAIN_REFSPEC"; then
  git config --add remote.origin.fetch "$MAIN_REFSPEC"
fi
git fetch --no-tags origin refs/heads/main:refs/remotes/origin/main

# Preserve locally committed work: only migrate branches when all existing
# commits are reachable from upstream main. Never reset, rebase, or force.
git merge-base --is-ancestor HEAD refs/remotes/origin/main ||
  fail "local $CURRENT_BRANCH contains commits not in origin/main; refusing migration"

if [ "$CURRENT_BRANCH" != "main" ]; then
  if git show-ref --verify --quiet refs/heads/main; then
    git merge-base --is-ancestor refs/heads/main refs/remotes/origin/main ||
      fail "existing local main diverges from origin/main; refusing migration"
    git checkout main
  else
    git checkout -b main --track origin/main
  fi
  echo "[OK] legacy checkout migrated to main"
fi

git merge --ff-only refs/remotes/origin/main
git branch --set-upstream-to=origin/main main
echo "[OK] main updated to $(git rev-parse --short HEAD)"

bash ./scripts/install-master.sh "$CONFIG"
bash ./scripts/verify-manager-ssh.sh "$CONFIG"
