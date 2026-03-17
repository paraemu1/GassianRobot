#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORCE_PLAIN="${MASTER_TUI_FORCE_PLAIN:-0}"
DRY_RUN="${MASTER_TUI_DRY_RUN:-0}"

have_whiptail=0
if command -v whiptail >/dev/null 2>&1; then
  have_whiptail=1
fi
if [[ "$FORCE_PLAIN" == "1" ]]; then
  have_whiptail=0
fi

safe_clear() {
  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear || true
  fi
}

pause_terminal() {
  if [[ ! -t 0 ]]; then
    return 0
  fi
  echo ""
  read -rp "Press Enter to continue... " _
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] $*"
    pause_terminal
    return 0
  fi
  safe_clear
  echo "Running: $*"
  echo ""
  set +e
  "$@"
  local code=$?
  set -e
  echo ""
  if [[ "$code" -ne 0 ]]; then
    echo "Command failed with exit code $code"
  fi
  pause_terminal
  return "$code"
}

menu_choice() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")

  if [[ "$have_whiptail" -eq 1 ]]; then
    whiptail --title "$title" --menu "$prompt" 26 120 18 "${items[@]}" 3>&1 1>&2 2>&3 || true
    return 0
  fi

  echo "$title"
  echo "$prompt"
  echo ""

  local -a keys=()
  local i idx=1
  for ((i=0; i<${#items[@]}; i+=2)); do
    keys+=("${items[$i]}")
    echo "${idx}) ${items[$((i+1))]}"
    idx=$((idx+1))
  done
  echo ""

  local pick
  read -rp "Choose: " pick
  if [[ ! "$pick" =~ ^[0-9]+$ || "$pick" -lt 1 || "$pick" -gt ${#keys[@]} ]]; then
    echo ""
    return 0
  fi
  echo "${keys[$((pick-1))]}"
}

show_banner() {
  safe_clear
  cat <<'EOF'
=============================================
   GassianRobot Master TUI
   Demo + Debug + Workflow Control Center
=============================================
EOF
}

show_demo_notes() {
  safe_clear
  cat <<'EOF'
Demo Mode recommended sequence:

1) Connection report (USB-C / l4tbr0)
2) Manual drive app (improved)
3) Autonomous scan dry-run (if robot disconnected)
4) Live auto-scan helper (when robot connected)
5) Optional: open full workflow TUI

Safety:
- Keep robot on floor in open space before sending Nav2 goals.
- Keep an operator near E-stop / manual override.
EOF
  pause_terminal
}

demo_menu() {
  while true; do
    local choice
    choice="$(menu_choice \
      "Master TUI - Demo" \
      "Demo-focused actions" \
      "1" "Connection report" \
      "2" "Manual drive app (improved teleop)" \
      "3" "Run autonomous scan mission (DRY-RUN)" \
      "4" "Launch live auto-scan helper" \
      "5" "Open control_center.sh" \
      "6" "Open gs_tui.sh (full workflow)" \
      "7" "Demo checklist notes" \
      "8" "Back")"

    case "$choice" in
      1) run_cmd "${SCRIPT_DIR}/control_center.sh" ;;
      2) run_cmd "${SCRIPT_DIR}/teleop_drive_app.sh" ;;
      3)
        safe_clear
        echo "Running autonomous scan mission in DRY_RUN mode..."
        echo ""
        set +e
        DRY_RUN=1 "${SCRIPT_DIR}/run_auto_scan_mission.sh"
        code=$?
        set -e
        echo ""
        if [[ "$code" -ne 0 ]]; then
          echo "Mission dry-run failed with exit code $code"
        fi
        pause_terminal
        ;;
      4) run_cmd "${SCRIPT_DIR}/launch_live_auto_scan.sh" ;;
      5) run_cmd "${SCRIPT_DIR}/control_center.sh" ;;
      6) run_cmd "${SCRIPT_DIR}/gs_tui.sh" ;;
      7) show_demo_notes ;;
      8|"") return 0 ;;
      *) ;;
    esac
  done
}

debug_menu() {
  while true; do
    local choice
    choice="$(menu_choice \
      "Master TUI - Debug" \
      "Diagnostics, audits, and troubleshooting" \
      "1" "Software readiness audit" \
      "2" "Autonomy preflight (software-only)" \
      "3" "Autonomy preflight (require robot)" \
      "4" "ROS health check" \
      "5" "List recent run logs" \
      "6" "Open control_center.sh" \
      "7" "Open gs_tui.sh in safe-mode" \
      "8" "Back")"

    case "$choice" in
      1) run_cmd "${SCRIPT_DIR}/software_readiness_audit.sh" ;;
      2) run_cmd "${SCRIPT_DIR}/preflight_autonomy.sh" ;;
      3)
        if [[ "$DRY_RUN" == "1" ]]; then
          echo "[DRY-RUN] NEED_ROBOT=1 ${SCRIPT_DIR}/preflight_autonomy.sh"
          pause_terminal
        else
          safe_clear
          NEED_ROBOT=1 "${SCRIPT_DIR}/preflight_autonomy.sh" || true
          pause_terminal
        fi
        ;;
      4) run_cmd "${SCRIPT_DIR}/ros_health_check.sh" ;;
      5)
        safe_clear
        ls -lt "${REPO_ROOT}/runs" | sed -n '1,40p'
        pause_terminal
        ;;
      6) run_cmd "${SCRIPT_DIR}/control_center.sh" ;;
      7)
        if [[ "$DRY_RUN" == "1" ]]; then
          echo "[DRY-RUN] ${SCRIPT_DIR}/gs_tui.sh --safe-mode"
          pause_terminal
        else
          run_cmd "${SCRIPT_DIR}/gs_tui.sh" --safe-mode
        fi
        ;;
      8|"") return 0 ;;
      *) ;;
    esac
  done
}

workflow_menu() {
  while true; do
    local choice
    choice="$(menu_choice \
      "Master TUI - Workflow" \
      "Operational workflows" \
      "1" "Run full gs_tui workflow" \
      "2" "Run control center" \
      "3" "Run autonomous mission (live)" \
      "4" "Run autonomous mission (dry-run)" \
      "5" "Back")"

    case "$choice" in
      1) run_cmd "${SCRIPT_DIR}/gs_tui.sh" ;;
      2) run_cmd "${SCRIPT_DIR}/control_center.sh" ;;
      3)
        if [[ "$DRY_RUN" == "1" ]]; then
          echo "[DRY-RUN] ${SCRIPT_DIR}/run_auto_scan_mission.sh"
          pause_terminal
        else
          run_cmd "${SCRIPT_DIR}/run_auto_scan_mission.sh"
        fi
        ;;
      4)
        safe_clear
        set +e
        DRY_RUN=1 "${SCRIPT_DIR}/run_auto_scan_mission.sh"
        set -e
        pause_terminal
        ;;
      5|"") return 0 ;;
      *) ;;
    esac
  done
}

main_menu() {
  while true; do
    show_banner
    local mode="LIVE"
    [[ "$DRY_RUN" == "1" ]] && mode="DRY-RUN"

    local choice
    choice="$(menu_choice \
      "Master TUI (${mode})" \
      "Choose area" \
      "1" "Demo Mode" \
      "2" "Debug Mode" \
      "3" "Workflow Mode" \
      "4" "Toggle dry-run mode" \
      "5" "Exit")"

    case "$choice" in
      1) demo_menu ;;
      2) debug_menu ;;
      3) workflow_menu ;;
      4)
        if [[ "$DRY_RUN" == "1" ]]; then DRY_RUN=0; else DRY_RUN=1; fi
        ;;
      5|"")
        echo "Bye."
        return 0
        ;;
      *) ;;
    esac
  done
}

main_menu
