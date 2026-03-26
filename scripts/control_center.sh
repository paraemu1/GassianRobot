#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRY_RUN="${CONTROL_TUI_DRY_RUN:-0}"
TUI_FORCE_PLAIN="${CONTROL_TUI_FORCE_PLAIN:-${GASSIAN_TUI_FORCE_PLAIN:-0}}"
TUI_USE_WHIPTAIL="${CONTROL_TUI_USE_WHIPTAIL:-${GASSIAN_TUI_USE_WHIPTAIL:-1}}"
TUI_AUTOTEST="${CONTROL_TUI_AUTOTEST:-${GASSIAN_TUI_AUTOTEST:-0}}"

# shellcheck source=./lib/_tui_common.sh
source "${SCRIPT_DIR}/lib/_tui_common.sh"
tui_init

connection_report() {
  tui_safe_clear
  echo "=== Create 3 USB-C connection report ==="
  echo "Repo: $REPO_ROOT"
  echo ""

  local iface="l4tbr0"
  local iface_state="missing"
  if ip link show "$iface" >/dev/null 2>&1; then
    iface_state="present"
  fi

  local oper="unknown"
  if [[ "$iface_state" == "present" ]]; then
    oper="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo unknown)"
  fi

  local ping_ok="no"
  if ping -I "$iface" -c 1 -W 1 192.168.186.2 >/dev/null 2>&1; then
    ping_ok="yes"
  fi

  local fw="unreachable"
  if [[ "$ping_ok" == "yes" ]]; then
    fw="$(curl --interface "$iface" -sS http://192.168.186.2/home | grep -o 'version=\"[^\"]*\"\|rosversionname=\"[^\"]*\"' | paste -sd ', ' - || true)"
    fw="${fw:-reachable (metadata parse failed)}"
  fi

  local docker_ok="no"
  if docker info >/dev/null 2>&1; then
    docker_ok="yes"
  fi

  echo "Interface ($iface): $iface_state"
  echo "Interface state:    $oper"
  echo "Robot ping:         $ping_ok"
  echo "Robot metadata:     $fw"
  echo "Docker daemon:      $docker_ok"
  echo ""
  echo "Tip: For USB-C-only Create 3 control, l4tbr0 should be UP and ping should be yes."
  tui_pause
}

guided_nav2_start() {
  tui_safe_clear
  cat <<'EOF'
Guided Nav2 + RTAB-Map startup (non-destructive):

Terminal A:
  ./scripts/robot/run_robot_runtime_container.sh
  # inside container:
  source /opt/ros/humble/setup.bash
  # keep this shell open; use separate host shells for the wrappers below

Terminal B (host):
  ./scripts/robot/run_oak_camera.sh
  ./scripts/robot/run_rtabmap_rgbd.sh

Terminal C (host):
  ./scripts/robot/run_nav2_with_rtabmap.sh

Then send a goal:
  ./scripts/robot/send_nav2_goal.sh 1.0 0.0 0.0 1.0

Note: Keep robot on the floor in open area before sending goals.
EOF
  tui_pause
}

open_easy_menu() {
  EASY_AUTONOMY_TUI_DRY_RUN="$DRY_RUN" \
  GASSIAN_TUI_FORCE_PLAIN="$TUI_FORCE_PLAIN" \
  GASSIAN_TUI_USE_WHIPTAIL="$TUI_USE_WHIPTAIL" \
  GASSIAN_TUI_AUTOTEST="$TUI_AUTOTEST" \
    "${SCRIPT_DIR}/easy_autonomy_tui.sh"
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
      "Advanced Robot Control Center (${mode})" \
      "Use this only when the Easy Robot Scan Menu is not enough." \
      "1" "Easy robot scan menu (recommended)" \
      "2" "Check robot USB-C link" \
      "3" "Manual drive app" \
      "4" "GameCube controller teleop (hidraw adapter)" \
      "5" "Legacy arrow-key teleop (fallback)" \
      "6" "ROS health check" \
      "7" "Autonomy preflight (software-only)" \
      "8" "Software readiness audit" \
      "9" "Guided Nav2 + scan startup notes" \
      "10" "Toggle dry-run mode" \
      "11" "Exit")"; then
      echo "Bye."
      return 0
    fi

    case "$choice" in
      1) open_easy_menu ;;
      2) connection_report ;;
      3) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/teleop_drive_app.sh" ;;
      4) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/teleop_gamecube_hidraw.sh" ;;
      5) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/teleop_arrow_keys.sh" ;;
      6) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/ros_health_check.sh" ;;
      7) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/robot/preflight_autonomy.sh" ;;
      8) tui_run_cmd "$DRY_RUN" "${SCRIPT_DIR}/build/software_readiness_audit.sh" ;;
      9) guided_nav2_start ;;
      10)
        if [[ "$DRY_RUN" == "1" ]]; then
          DRY_RUN=0
        else
          DRY_RUN=1
        fi
        ;;
      11)
        echo "Bye."
        return 0
        ;;
      *)
        ;;
    esac
  done
}

main_menu
