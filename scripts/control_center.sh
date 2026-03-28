#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

master_cmd=("${SCRIPT_DIR}/master_tui.sh" --start-section robot-tools)

if [[ "${CONTROL_TUI_DRY_RUN:-0}" == "1" ]]; then
  master_cmd+=(--safe-mode)
fi
if [[ "${CONTROL_TUI_FORCE_PLAIN:-${GASSIAN_TUI_FORCE_PLAIN:-0}}" == "1" ]]; then
  master_cmd+=(--force-plain)
fi

exec env \
  MASTER_TUI_AUTOTEST="${CONTROL_TUI_AUTOTEST:-${GASSIAN_TUI_AUTOTEST:-0}}" \
  "${master_cmd[@]}"
