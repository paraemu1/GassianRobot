#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SAFE_MODE="${GS_TUI_SAFE_MODE:-0}"
FORCE_PLAIN="${GS_TUI_FORCE_PLAIN:-0}"
SELF_TEST=0

usage() {
  cat <<'USAGE'
Compatibility wrapper for the unified master TUI.

Usage:
  ./scripts/gs_tui.sh [--safe-mode] [--force-plain]
  ./scripts/gs_tui.sh --self-test

Options:
  --safe-mode    Use dry-run mode for supported actions.
  --force-plain  Use the shell fallback instead of ncurses.
  --self-test    Run the non-destructive TUI test suite and exit.
  -h, --help     Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --safe-mode)
      SAFE_MODE=1
      shift 1
      ;;
    --force-plain)
      FORCE_PLAIN=1
      shift 1
      ;;
    --self-test)
      SELF_TEST=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$SELF_TEST" -eq 1 ]]; then
  exec "${SCRIPT_DIR}/tests/test_gs_tui.sh"
fi

master_cmd=("${SCRIPT_DIR}/master_tui.sh" --start-section gaussian)
if [[ "$SAFE_MODE" == "1" ]]; then
  master_cmd+=(--safe-mode)
fi
if [[ "$FORCE_PLAIN" == "1" ]]; then
  master_cmd+=(--force-plain)
fi
exec env MASTER_TUI_AUTOTEST="${GS_TUI_AUTOTEST:-0}" "${master_cmd[@]}"
