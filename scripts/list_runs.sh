#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

run_utils_list_runs "$REPO_ROOT"
latest="$(run_utils_latest_run "$REPO_ROOT" || true)"
if [[ -n "$latest" ]]; then
  echo ""
  echo "Latest: ${latest#${REPO_ROOT}/}"
else
  echo ""
  echo "Latest: (none)"
fi
