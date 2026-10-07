#!/usr/bin/env bash
# Runs all tests that work off-device: controller (pytest) and winctl (Pester, needs pwsh).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> controller (pytest)"
(cd "$root/controller" && python3 -m pytest -q)

if command -v pwsh >/dev/null 2>&1; then
  echo "==> winctl (Pester)"
  pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; \$r = Invoke-Pester -Path '$root/winctl/tests' -PassThru; exit \$r.FailedCount"
else
  echo "==> winctl skipped (pwsh not installed)"
fi
