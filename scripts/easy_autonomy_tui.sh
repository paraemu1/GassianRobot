#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRY_RUN="${EASY_AUTONOMY_TUI_DRY_RUN:-0}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/gassianrobot_easy_autonomy_last_run"
TUI_FORCE_PLAIN="${EASY_AUTONOMY_TUI_FORCE_PLAIN:-${GASSIAN_TUI_FORCE_PLAIN:-0}}"
TUI_USE_WHIPTAIL="${EASY_AUTONOMY_TUI_USE_WHIPTAIL:-${GASSIAN_TUI_USE_WHIPTAIL:-1}}"
TUI_AUTOTEST="${EASY_AUTONOMY_TUI_AUTOTEST:-${GASSIAN_TUI_AUTOTEST:-0}}"

# shellcheck source=./lib/_tui_common.sh
source "${SCRIPT_DIR}/lib/_tui_common.sh"
# shellcheck source=./lib/_run_utils.sh
source "${SCRIPT_DIR}/lib/_run_utils.sh"
tui_init

default_run_name() {
  printf "%s-easy-auto-scan" "$(date +%F-%H%M)"
}

load_last_run() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
    return 0
  fi
  return 1
}

save_last_run() {
  local run_name="$1"
  mkdir -p "$(dirname "$STATE_FILE")"
  printf "%s\n" "$run_name" > "$STATE_FILE"
}

current_run_label() {
  local last_run
  if last_run="$(load_last_run 2>/dev/null)"; then
    printf "%s" "$last_run"
  else
    printf "none"
  fi
}

run_with_run_name() {
  local run_name="$1"
  shift
  save_last_run "$run_name"
  tui_run_cmd "$DRY_RUN" env RUN_NAME="$run_name" "$@"
}

show_operator_intro() {
  tui_show_info \
    "Easy Robot Scan Menu" \
    "Use this menu if you just want to run the robot safely without learning the full project.\n\nRecommended order:\n1. Use \"Run Full Scan Now\" for the normal one-command workflow.\n2. Use \"Prepare Scan Stack Without Motion\" and then \"Start Prepared Mission\" only if you want to inspect everything before motion.\n3. Use \"Show Robot + Scan Status\" or \"Dock Robot\" whenever you need to check or recover the session.\n\nSafety:\n- Keep the robot on the floor.\n- Keep the dock area and the first meter ahead clear.\n- Stay nearby while it moves."
}

scan_safety_prompt() {
  tui_confirm \
    "Before starting motion:\n\n- Robot is on the dock or flat on the floor\n- Create 3 USB-C link is connected\n- OAK is connected\n- Floor area near the dock is clear\n- A person is nearby to supervise\n" \
    "Before Starting Motion"
}

status_report() {
  tui_safe_clear
  echo "=== Easy Scan Status ==="
  echo "Repo:      ${REPO_ROOT}"
  echo "Last run:  $(current_run_label)"
  echo ""
  echo "--- Dock status ---"
  bash "${SCRIPT_DIR}/robot/create3_dock_control.sh" status || true
  echo ""
  echo "--- Scan stack status ---"
  "${SCRIPT_DIR}/robot/launch_live_auto_scan.sh" status || true
  tui_pause
}

show_scan_history() {
  local remembered_run
  local count=0
  local content
  local line run_dir mode result has_db has_waypoints rel suffix

  remembered_run="$(current_run_label)"
  content="Recorded scan runs (newest first)\n\n"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS='|' read -r run_dir mode result has_db has_waypoints <<< "$line"
    rel="${run_dir#${REPO_ROOT}/}"
    suffix=""
    if [[ "$(basename "$run_dir")" == "$remembered_run" ]]; then
      suffix=" [last prepared run]"
    fi
    count=$((count + 1))
    content+="${count}. ${rel}${suffix} | ${mode} | ${result} | rtabmap_db=${has_db} | waypoints=${has_waypoints}\n"
  done < <(run_utils_scan_history_lines "$REPO_ROOT")

  if [[ "$count" -eq 0 ]]; then
    content+="No scan runs were found yet.\n\nA run appears here after a scan mission creates logs/auto_scan_mission.log."
  else
    content+="\nTotal scan runs: ${count}"
  fi

  tui_show_text "Previous Scan Runs" "$content"
}

base_check() {
  tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/create3_base_health_check.sh"
}

full_scan_now() {
  local run_name
  run_name="$(default_run_name)"
  if ! scan_safety_prompt; then
    return 0
  fi
  run_with_run_name "$run_name" "${SCRIPT_DIR}/robot/launch_live_auto_scan.sh" start
}

bring_up_only() {
  local run_name
  run_name="$(default_run_name)"
  if ! scan_safety_prompt; then
    return 0
  fi
  run_with_run_name "$run_name" "${SCRIPT_DIR}/robot/launch_live_auto_scan.sh" start-only
}

start_mission_only() {
  local run_name
  if ! run_name="$(load_last_run 2>/dev/null)"; then
    tui_show_info \
      "No Prepared Run" \
      "There is no remembered run name yet.\n\nUse \"Prepare Scan Stack Without Motion\" first, or use \"Run Full Scan Now\" for the one-command path."
    return 0
  fi
  if ! scan_safety_prompt; then
    return 0
  fi
  run_with_run_name "$run_name" "${SCRIPT_DIR}/robot/launch_live_auto_scan.sh" mission
}

dock_robot() {
  tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/create3_dock_control.sh" dock
}

undock_robot() {
  if ! tui_confirm "Undock the robot now?\n\nMake sure the floor area ahead of the dock is clear." "Undock Robot"; then
    return 0
  fi
  tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/create3_dock_control.sh" undock
}

open_advanced_menu() {
  CONTROL_TUI_DRY_RUN="$DRY_RUN" \
  GASSIAN_TUI_FORCE_PLAIN="$TUI_FORCE_PLAIN" \
  GASSIAN_TUI_USE_WHIPTAIL="$TUI_USE_WHIPTAIL" \
  GASSIAN_TUI_AUTOTEST="$TUI_AUTOTEST" \
    "${SCRIPT_DIR}/control_center.sh"
}

main_menu() {
  while true; do
    local mode="LIVE"
    if [[ "$DRY_RUN" == "1" ]]; then
      mode="DRY-RUN"
    fi

    local choice
    if [[ "$TUI_HAVE_WHIPTAIL" != "1" ]]; then
      tui_safe_clear
    fi
    if ! choice="$(tui_menu_choice \
      "Easy Robot Scan Menu (${mode})" \
      "Last prepared run: $(current_run_label)" \
      "1" "Run Full Scan Now (recommended)" \
      "2" "Prepare Scan Stack Without Motion" \
      "3" "Start Prepared Mission" \
      "4" "Show Robot + Scan Status" \
      "5" "List Previous Scan Runs" \
      "6" "Run Robot Health Check" \
      "7" "Dock Robot" \
      "8" "Undock Robot" \
      "9" "Manual Drive Control" \
      "10" "Open Advanced Robot Tools" \
      "11" "Show Quick Guide" \
      "12" "Toggle dry-run mode" \
      "13" "Exit")"; then
      echo "Bye."
      return 0
    fi

    case "$choice" in
      1) full_scan_now ;;
      2) bring_up_only ;;
      3) start_mission_only ;;
      4) status_report ;;
      5) show_scan_history ;;
      6) base_check ;;
      7) dock_robot ;;
      8) undock_robot ;;
      9) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/teleop_drive_app.sh" ;;
      10) open_advanced_menu ;;
      11) show_operator_intro ;;
      12)
        if [[ "$DRY_RUN" == "1" ]]; then
          DRY_RUN=0
        else
          DRY_RUN=1
        fi
        ;;
      13)
        echo "Bye."
        return 0
        ;;
      *)
        ;;
    esac
  done
}

show_operator_intro
main_menu
