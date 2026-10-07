#!/usr/bin/env bash
# Daily self-update (windows-controller-update.timer). Fast-forward only: a diverged or dirty
# checkout is left alone. When controller/ changed, the idempotent install.sh is re-run, which
# refreshes the venv / unit files and restarts the service.
set -euo pipefail

CONTROLLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$CONTROLLER_DIR/.." && pwd)"
log() { echo "$(date "+%Y-%m-%dT%H:%M:%S%z") $*"; }

cd "$REPO"
branch="$(git rev-parse --abbrev-ref HEAD)"
before="$(git rev-parse HEAD)"
git fetch -q origin "$branch"
if ! git merge -q --ff-only "origin/$branch"; then
  log "update skipped: $branch cannot be fast-forwarded (local changes?)"
  exit 1
fi
after="$(git rev-parse HEAD)"
if [[ "$before" == "$after" ]]; then
  log "up to date ($(git rev-parse --short HEAD))"
  exit 0
fi
log "updated ${before:0:7} -> ${after:0:7}"
if git diff --quiet "$before" "$after" -- controller/; then
  log "no controller changes"
  exit 0
fi
log "controller changed; re-running install.sh"
"$CONTROLLER_DIR/install.sh"
