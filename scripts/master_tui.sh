#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SAFE_MODE="${MASTER_TUI_SAFE_MODE:-${MASTER_TUI_DRY_RUN:-0}}"
FORCE_PLAIN="${MASTER_TUI_FORCE_PLAIN:-${GASSIAN_TUI_FORCE_PLAIN:-${GS_TUI_FORCE_PLAIN:-0}}}"
AUTOTEST="${MASTER_TUI_AUTOTEST:-${GASSIAN_TUI_AUTOTEST:-${GS_TUI_AUTOTEST:-0}}}"
START_SECTION="${MASTER_TUI_START_SECTION:-}"

usage() {
  cat <<'USAGE'
Unified master TUI launcher.

Usage:
  ./scripts/master_tui.sh [--safe-mode] [--force-plain] [--start-section <section>]

Options:
  --safe-mode              Preview or dry-run supported actions.
  --force-plain            Use the shell fallback instead of ncurses.
  --start-section <name>   Open a section first, then return to the main menu.
                           Supported: robot-scan, robot-tools, handheld, gaussian, runs, builds, diagnostics
  -h, --help               Show this help.

Environment:
  MASTER_TUI_SAFE_MODE=1   Same as --safe-mode.
  MASTER_TUI_DRY_RUN=1     Compatibility alias for --safe-mode.
  MASTER_TUI_FORCE_PLAIN=1 Same as --force-plain.
  MASTER_TUI_AUTOTEST=1    Skip pauses in the plain fallback where possible.
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
    --start-section)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --start-section" >&2
        exit 1
      fi
      START_SECTION="$2"
      shift 2
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

if [[ "$FORCE_PLAIN" == "1" || ! -t 0 || ! -t 1 ]] || ! command -v python3 >/dev/null 2>&1; then
  legacy_cmd=("${SCRIPT_DIR}/master_tui_legacy.sh" --force-plain)
  if [[ "$SAFE_MODE" == "1" ]]; then
    legacy_cmd+=(--safe-mode)
  fi
  if [[ -n "$START_SECTION" ]]; then
    legacy_cmd+=(--start-section "$START_SECTION")
  fi
  exec env MASTER_TUI_AUTOTEST="$AUTOTEST" "${legacy_cmd[@]}"
fi

ncurses_cmd=(python3 "${SCRIPT_DIR}/master_ncurses_tui.py")
if [[ "$SAFE_MODE" == "1" ]]; then
  ncurses_cmd+=(--safe-mode)
fi
if [[ -n "$START_SECTION" ]]; then
  ncurses_cmd+=(--start-section "$START_SECTION")
fi
exec "${ncurses_cmd[@]}"
