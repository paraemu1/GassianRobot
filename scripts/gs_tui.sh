#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SAFE_MODE=0
FORCE_PLAIN=0
SELF_TEST=0

usage() {
  cat <<'USAGE'
Gaussian workflow TUI launcher.

Usage:
  ./scripts/gs_tui.sh [--safe-mode] [--force-plain]
  ./scripts/gs_tui.sh --self-test

Options:
  --safe-mode    Use dry-run mode for supported actions.
  --force-plain  Use the legacy plain/whiptail shell menu instead of ncurses.
  --self-test    Run the non-destructive shell TUI test suite and exit.
  -h, --help     Show this help.
USAGE
}

if [[ "${GS_TUI_FORCE_PLAIN:-0}" == "1" ]]; then
  FORCE_PLAIN=1
fi
if [[ "${GS_TUI_SAFE_MODE:-0}" == "1" ]]; then
  SAFE_MODE=1
fi

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

if [[ "$FORCE_PLAIN" -eq 1 || ! -t 0 || ! -t 1 ]]; then
  legacy_cmd=("${SCRIPT_DIR}/gs_tui_legacy.sh")
  if [[ "$SAFE_MODE" -eq 1 ]]; then
    legacy_cmd+=(--safe-mode)
  fi
  exec "${legacy_cmd[@]}"
fi

ncurses_cmd=(python3 "${SCRIPT_DIR}/gs_ncurses_tui.py")
if [[ "$SAFE_MODE" -eq 1 ]]; then
  ncurses_cmd+=(--safe-mode)
fi
exec "${ncurses_cmd[@]}"
