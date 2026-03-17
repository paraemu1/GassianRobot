#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

run_utils_list_runs "$REPO_ROOT"

latest_any="$(run_utils_latest_run "$REPO_ROOT" || true)"
latest_trainable="$(run_utils_latest_trainable_run "$REPO_ROOT" || true)"
latest_viewer="$(run_utils_latest_viewer_ready_run "$REPO_ROOT" || true)"
latest_logs="$(run_utils_latest_with_train_logs_run "$REPO_ROOT" || true)"

echo ""
if [[ -n "$latest_any" ]]; then
  echo "Latest (any):        ${latest_any#${REPO_ROOT}/}"
else
  echo "Latest (any):        (none)"
fi

if [[ -n "$latest_trainable" ]]; then
  echo "Latest (trainable):  ${latest_trainable#${REPO_ROOT}/}"
else
  echo "Latest (trainable):  (none)"
fi

if [[ -n "$latest_viewer" ]]; then
  echo "Latest (viewer):     ${latest_viewer#${REPO_ROOT}/}"
else
  echo "Latest (viewer):     (none)"
fi

if [[ -n "$latest_logs" ]]; then
  echo "Latest (train logs): ${latest_logs#${REPO_ROOT}/}"
else
  echo "Latest (train logs): (none)"
fi
