#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${MASTER_TUI_DRY_RUN:-0}"
TUI_FORCE_PLAIN="${MASTER_TUI_FORCE_PLAIN:-${GASSIAN_TUI_FORCE_PLAIN:-0}}"
TUI_USE_WHIPTAIL="${MASTER_TUI_USE_WHIPTAIL:-${GASSIAN_TUI_USE_WHIPTAIL:-1}}"
TUI_AUTOTEST="${MASTER_TUI_AUTOTEST:-${GASSIAN_TUI_AUTOTEST:-0}}"

# shellcheck source=./lib/_tui_common.sh
source "${SCRIPT_DIR}/lib/_tui_common.sh"
tui_init

show_banner() {
  tui_safe_clear
  cat <<'EOF'
=============================================
   GassianRobot Launcher
   Easy Scan + Advanced Tools + Gaussian UI
=============================================
EOF
}

open_easy_menu() {
  EASY_AUTONOMY_TUI_DRY_RUN="$DRY_RUN" \
  GASSIAN_TUI_FORCE_PLAIN="$TUI_FORCE_PLAIN" \
  GASSIAN_TUI_USE_WHIPTAIL="$TUI_USE_WHIPTAIL" \
  GASSIAN_TUI_AUTOTEST="$TUI_AUTOTEST" \
    "${SCRIPT_DIR}/easy_autonomy_tui.sh"
}

open_control_center() {
  CONTROL_TUI_DRY_RUN="$DRY_RUN" \
  GASSIAN_TUI_FORCE_PLAIN="$TUI_FORCE_PLAIN" \
  GASSIAN_TUI_USE_WHIPTAIL="$TUI_USE_WHIPTAIL" \
  GASSIAN_TUI_AUTOTEST="$TUI_AUTOTEST" \
    "${SCRIPT_DIR}/control_center.sh"
}

open_gaussian_menu() {
  if [[ "$DRY_RUN" == "1" ]]; then
    GS_TUI_SAFE_MODE=1 "${SCRIPT_DIR}/gs_tui.sh"
    return 0
  fi
  "${SCRIPT_DIR}/gs_tui.sh"
}

main_menu() {
  while true; do
    show_banner
    local mode="LIVE"
    if [[ "$DRY_RUN" == "1" ]]; then
      mode="DRY-RUN"
    fi

    local choice
    if ! choice="$(tui_menu_choice \
      "GassianRobot Launcher (${mode})" \
      "Start with the Easy Robot Scan Menu unless you already know you need something else." \
      "1" "Easy robot scan menu (recommended)" \
      "2" "Advanced robot tools" \
      "3" "Gaussian capture / training workflow" \
      "4" "Software readiness audit" \
      "5" "Toggle dry-run mode" \
      "6" "Exit")"; then
      echo "Bye."
      return 0
    fi

    case "$choice" in
      1) open_easy_menu ;;
      2) open_control_center ;;
      3) open_gaussian_menu ;;
      4) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/build/software_readiness_audit.sh" ;;
      5)
        if [[ "$DRY_RUN" == "1" ]]; then
          DRY_RUN=0
        else
          DRY_RUN=1
        fi
        ;;
      6)
        echo "Bye."
        return 0
        ;;
      *)
        ;;
    esac
  done
}

main_menu
