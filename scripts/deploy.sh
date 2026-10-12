#!/usr/bin/env bash
# Test, push, then pull the change onto the Pi now instead of waiting for the daily timers.
# Windows follows on its own (12:00 daily, or `/win update` in Discord / `winctl update` on the PC);
# this script cannot reach it unless OpenSSH + Tailscale are set up on the Mac.
#
#   scripts/deploy.sh [--no-test] [--pi HOST]      (HOST default: $WPC_PI_HOST or wpc-controller)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_tests=1 pi="${WPC_PI_HOST:-wpc-controller}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-test) run_tests=0; shift ;;
    --pi) pi="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$root"
branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree is dirty: commit first (nothing is deployed from uncommitted changes)" >&2
  exit 1
fi

if [[ $run_tests -eq 1 ]]; then
  "$root/scripts/test.sh"
fi

echo "==> push $branch"
git push origin "$branch"

echo "==> Raspberry Pi ($pi): windows-controller-update.service"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$pi" "sudo systemctl start windows-controller-update.service && journalctl -u windows-controller-update.service -n 3 --no-pager"; then
  echo "    Pi updated"
else
  echo "    could not reach/update the Pi; it will self-update at ~04:00" >&2
fi

echo "==> Windows: updates itself at 12:00, or run /win update (Discord) / winctl update (PC)"
