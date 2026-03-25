#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORCE_PLAIN="${CONTROL_TUI_FORCE_PLAIN:-0}"
DRY_RUN="${CONTROL_TUI_DRY_RUN:-0}"

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

show_info() {
  local msg="$1"
  if [[ "$have_whiptail" -eq 1 ]]; then
    whiptail --title "Control Center" --msgbox "$msg" 16 100
  else
    echo "$msg"
    pause_terminal
  fi
}

menu_choice() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")

  if [[ "$have_whiptail" -eq 1 ]]; then
    whiptail --title "$title" --menu "$prompt" 24 110 16 "${items[@]}" 3>&1 1>&2 2>&3 || true
    return 0
  fi

  echo "$title"
  echo "$prompt"
  echo ""
  local -a keys=()
  local idx=1
  local i
  for ((i=0; i<${#items[@]}; i+=2)); do
    keys+=("${items[$i]}")
    echo "${idx}) ${items[$((i+1))]}"
    idx=$((idx + 1))
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

connection_report() {
  safe_clear
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
    fw="$(curl --interface "$iface" -sS http://192.168.186.2/home | grep -o 'version="[^"]*"\|rosversionname="[^"]*"' | paste -sd ', ' - || true)"
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
  pause_terminal
}

show_demo_help() {
  show_info "Demo flow (recommended):\n\n1) Run: Connection report\n2) Run: Manual drive app (improved)\n3) If robot connected and on floor, use Nav2 guided startup\n4) Send a goal with scripts/send_nav2_goal.sh\n\nSafety: keep robot on floor and clear area before autonomous commands."
}

guided_nav2_start() {
  safe_clear
  cat <<'EOF'
Guided Nav2 + RTAB-Map startup (non-destructive):

Terminal A:
  ./scripts/run_robot_runtime_container.sh
  # inside container:
  source /opt/ros/humble/setup.bash
  # keep this shell open; use separate host shells for the wrappers below

Terminal B (host):
  ./scripts/run_oak_camera.sh
  ./scripts/run_rtabmap_rgbd.sh

Terminal C (host):
  ./scripts/run_nav2_with_rtabmap.sh

Then send a goal:
  ./scripts/send_nav2_goal.sh 1.0 0.0 0.0 1.0

Note: Keep robot on the floor in open area before sending goals.
EOF
  pause_terminal
}

main_menu() {
  while true; do
    local mode="LIVE"
    if [[ "$DRY_RUN" == "1" ]]; then
      mode="DRY-RUN"
    fi

    local choice
    choice="$(menu_choice \
      "Create3 Control Center (${mode})" \
      "Pick an action" \
      "1" "Connection report (USB-C / l4tbr0)" \
      "2" "Manual drive app (improved teleop)" \
      "3" "GameCube controller teleop (hidraw adapter)" \
      "4" "Legacy arrow-key teleop (fallback)" \
      "5" "ROS health check" \
      "6" "Guided Nav2 + scan startup (instructions)" \
      "7" "Run software readiness audit" \
      "8" "Run autonomy preflight (software-only)" \
      "9" "Run autonomous scan mission (dry-run)" \
      "10" "Start live auto-scan (one command)" \
      "11" "Demo checklist" \
      "12" "Toggle dry-run mode" \
      "13" "Exit")"

    case "$choice" in
      1)
        connection_report
        ;;
      2)
        run_cmd "${SCRIPT_DIR}/teleop_drive_app.sh"
        ;;
      3)
        run_cmd "${SCRIPT_DIR}/teleop_gamecube_hidraw.sh"
        ;;
      4)
        run_cmd "${SCRIPT_DIR}/teleop_arrow_keys.sh"
        ;;
      5)
        run_cmd "${SCRIPT_DIR}/ros_health_check.sh"
        ;;
      6)
        guided_nav2_start
        ;;
      7)
        run_cmd "${SCRIPT_DIR}/software_readiness_audit.sh"
        ;;
      8)
        run_cmd "${SCRIPT_DIR}/preflight_autonomy.sh"
        ;;
      9)
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
      10)
        run_cmd "${SCRIPT_DIR}/start_live_auto_scan.sh"
        ;;
      11)
        show_demo_help
        ;;
      12)
        if [[ "$DRY_RUN" == "1" ]]; then
          DRY_RUN=0
        else
          DRY_RUN=1
        fi
        ;;
      13|"")
        echo "Bye."
        return 0
        ;;
      *)
        ;;
    esac
  done
}

main_menu
