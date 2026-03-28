#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/_run_utils.sh"

DEFAULT_ITERS=30000
DEFAULT_PORT=7007
DEFAULT_DURATION=20
DEFAULT_DAYS=30
SAFE_MODE="${MASTER_TUI_SAFE_MODE:-${MASTER_TUI_DRY_RUN:-${GS_TUI_SAFE_MODE:-0}}}"
FORCE_PLAIN=0
AUTOTEST_MODE="${MASTER_TUI_AUTOTEST:-${GS_TUI_AUTOTEST:-0}}"
SELF_TEST_ONLY=0
START_SECTION="${MASTER_TUI_START_SECTION:-${GS_TUI_START_SECTION:-}}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/gassianrobot_easy_autonomy_last_run"
GUIDED_RUN_STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/gassianrobot_guided_run"

usage() {
  cat <<'USAGE'
Unified master TUI shell fallback.

Usage:
  ./scripts/master_tui.sh [--force-plain] [--safe-mode] [--start-section <section>]
  ./scripts/master_tui.sh --self-test

Options:
  --force-plain  Disable whiptail and use plain text menus.
  --safe-mode    Use dry-run mode for supported actions.
  --start-section <name>
                 Open a section first, then return to the main menu.
                 Supported: robot-scan, robot-tools, handheld, gaussian, runs, builds, diagnostics
  --self-test    Run the non-destructive TUI test suite and exit.
  -h, --help     Show this help.

Environment:
  MASTER_TUI_SAFE_MODE=1   Same as --safe-mode.
  MASTER_TUI_DRY_RUN=1     Compatibility alias for --safe-mode.
  MASTER_TUI_AUTOTEST=1    Skip pauses/prompts for automation.
  MASTER_TUI_START_SECTION Name of the section to open first.
  GS_TUI_*                Compatibility aliases for older wrappers.
USAGE
}

if [[ "${MASTER_TUI_FORCE_PLAIN:-${GS_TUI_FORCE_PLAIN:-0}}" == "1" ]]; then
  FORCE_PLAIN=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-plain)
      FORCE_PLAIN=1
      shift 1
      ;;
    --safe-mode)
      SAFE_MODE=1
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
    --self-test)
      SELF_TEST_ONLY=1
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

have_whiptail=0
if command -v whiptail >/dev/null 2>&1; then
  have_whiptail=1
fi
if [[ "$FORCE_PLAIN" -eq 1 ]]; then
  have_whiptail=0
fi

safe_clear() {
  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear || true
  fi
}

pause_terminal() {
  if [[ "$AUTOTEST_MODE" == "1" || ! -t 0 ]]; then
    return 0
  fi
  echo ""
  read -rp "Press Enter to return to the menu... " _
}

run_in_terminal() {
  safe_clear
  echo "Repo: ${REPO_ROOT}"
  echo "Command: $*"
  echo ""
  set +e
  "$@"
  local code=$?
  set -e
  echo ""
  if [[ "$code" -eq 0 ]]; then
    echo "Done."
  else
    echo "Command failed with exit code ${code}."
  fi
  pause_terminal
  return "$code"
}

preview_command() {
  safe_clear
  echo "SAFE MODE preview (command not executed):"
  printf '  %q ' "$@"
  echo ""
  pause_terminal
}

show_info() {
  local msg="$1"
  if [[ "$AUTOTEST_MODE" == "1" ]]; then
    echo "$msg"
    return 0
  fi
  if [[ "$have_whiptail" -eq 1 ]]; then
    whiptail --title "Info" --msgbox "$msg" 14 90
  else
    echo "$msg"
    pause_terminal
  fi
}

show_error() {
  local msg="$1"
  if [[ "$AUTOTEST_MODE" == "1" ]]; then
    echo "$msg" >&2
    return 0
  fi
  if [[ "$have_whiptail" -eq 1 ]]; then
    whiptail --title "Error" --msgbox "$msg" 14 90
  else
    echo "$msg" >&2
    pause_terminal
  fi
}

confirm_prompt() {
  local prompt="$1"
  if [[ "$AUTOTEST_MODE" == "1" ]]; then
    return 0
  fi
  if [[ "$have_whiptail" -eq 1 ]]; then
    whiptail --title "Confirm" --yesno "$prompt" 12 90
    return $?
  fi
  local ans
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

input_with_default() {
  local title="$1"
  local prompt="$2"
  local def="$3"
  local out

  if [[ "$AUTOTEST_MODE" == "1" ]]; then
    echo "$def"
    return 0
  fi

  if [[ "$have_whiptail" -eq 1 ]]; then
    out="$(whiptail --title "$title" --inputbox "$prompt" 12 90 "$def" 3>&1 1>&2 2>&3 || true)"
  else
    read -rp "${prompt} [${def}]: " out
  fi

  if [[ -z "$out" ]]; then
    echo "$def"
  else
    echo "$out"
  fi
}

is_positive_int() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*$ ]]
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

  echo "$title" >&2
  echo "$prompt" >&2
  echo "" >&2

  local -a keys=()
  local idx=1
  local i key desc
  for ((i=0; i<${#items[@]}; i+=2)); do
    key="${items[$i]}"
    desc="${items[$((i+1))]}"
    keys+=("$key")
    echo "${idx}) ${desc}" >&2
    idx=$((idx + 1))
  done

  echo "" >&2
  local pick
  read -rp "Choose: " pick
  if ! [[ "$pick" =~ ^[0-9]+$ ]]; then
    echo ""
    return 0
  fi
  if ((pick < 1 || pick > ${#keys[@]})); then
    echo ""
    return 0
  fi

  echo "${keys[$((pick-1))]}"
}

collect_runs_for_context() {
  local context="$1"
  local run_dir rel badges

  while IFS= read -r run_dir; do
    [[ -z "$run_dir" ]] && continue
    if run_utils_run_matches_context "$run_dir" "$context"; then
      rel="${run_dir#${REPO_ROOT}/}"
      badges="$(run_utils_run_status_badges "$run_dir")"
      echo "${run_dir}|${rel}|${badges}"
    fi
  done < <(run_utils_all_runs "$REPO_ROOT")
}

select_run() {
  local context="$1"
  local title="$2"
  local prompt="$3"
  local -a run_paths=()
  local -a run_labels=()
  local line path rel badges

  if [[ "$context" == "guided" ]]; then
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      rel="${path#${REPO_ROOT}/}"
      badges="$(run_utils_run_status_badges "$path")"
      run_paths+=("$path")
      if [[ -n "$badges" ]]; then
        run_labels+=("${rel} ${badges}")
      else
        run_labels+=("${rel}")
      fi
    done < <(collect_guided_runs)
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      path="${line%%|*}"
      rel="${line#*|}"
      rel="${rel%%|*}"
      badges="${line##*|}"
      run_paths+=("$path")
      if [[ -n "$badges" ]]; then
        run_labels+=("${rel} ${badges}")
      else
        run_labels+=("${rel}")
      fi
    done < <(collect_runs_for_context "$context")
  fi

  if [[ ${#run_paths[@]} -eq 0 ]]; then
    show_error "No runs available for context: ${context}."
    return 1
  fi

  if [[ "$have_whiptail" -eq 1 ]]; then
    local -a items=()
    local idx
    for idx in "${!run_paths[@]}"; do
      items+=("$((idx + 1))" "${run_labels[$idx]}")
    done
    local picked
    picked="$(whiptail --title "$title" --menu "$prompt" 24 120 16 "${items[@]}" 3>&1 1>&2 2>&3 || true)"
    if [[ -z "$picked" ]]; then
      return 1
    fi
    echo "${run_paths[$((picked - 1))]}"
    return 0
  fi

  safe_clear
  echo "$title" >&2
  echo "$prompt" >&2
  echo "" >&2
  local i
  for i in "${!run_paths[@]}"; do
    echo "$((i + 1))) ${run_labels[$i]}" >&2
  done
  echo "" >&2
  local picked
  read -rp "Choose run: " picked
  if ! [[ "$picked" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ((picked < 1 || picked > ${#run_paths[@]})); then
    return 1
  fi
  echo "${run_paths[$((picked - 1))]}"
}

select_trash_entry() {
  local trash_root="${REPO_ROOT}/runs/.trash"
  local -a entries=()
  local entry

  if [[ ! -d "$trash_root" ]]; then
    show_error "No trash directory exists yet (${trash_root})."
    return 1
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    entries+=("$(basename "$entry")")
  done < <(ls -1dt "${trash_root}"/*/ 2>/dev/null | sed 's:/$::' || true)

  if [[ ${#entries[@]} -eq 0 ]]; then
    show_error "No entries found in runs/.trash."
    return 1
  fi

  if [[ "$have_whiptail" -eq 1 ]]; then
    local -a items=()
    local idx
    for idx in "${!entries[@]}"; do
      items+=("$((idx + 1))" "${entries[$idx]}")
    done
    local picked
    picked="$(whiptail --title "Trash Entries" --menu "Select a trash entry." 24 110 16 "${items[@]}" 3>&1 1>&2 2>&3 || true)"
    if [[ -z "$picked" ]]; then
      return 1
    fi
    echo "${entries[$((picked - 1))]}"
    return 0
  fi

  safe_clear
  echo "Trash entries" >&2
  echo "" >&2
  local i
  for i in "${!entries[@]}"; do
    echo "$((i + 1))) ${entries[$i]}" >&2
  done
  echo "" >&2
  local picked
  read -rp "Choose entry: " picked
  if ! [[ "$picked" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ((picked < 1 || picked > ${#entries[@]})); then
    return 1
  fi
  echo "${entries[$((picked - 1))]}"
}

default_scan_run_name() {
  printf "%s-easy-auto-scan" "$(date +%F-%H%M)"
}

load_last_scan_run() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
    return 0
  fi
  return 1
}

save_last_scan_run() {
  local run_name="$1"
  mkdir -p "$(dirname "$STATE_FILE")"
  printf "%s\n" "$run_name" > "$STATE_FILE"
}

current_scan_run_label() {
  local last_run
  if last_run="$(load_last_scan_run 2>/dev/null)"; then
    printf "%s" "$last_run"
  else
    printf "none"
  fi
}

load_guided_run_override() {
  if [[ -f "$GUIDED_RUN_STATE_FILE" ]]; then
    cat "$GUIDED_RUN_STATE_FILE"
    return 0
  fi
  return 1
}

save_guided_run_override() {
  local run_dir="$1"
  mkdir -p "$(dirname "$GUIDED_RUN_STATE_FILE")"
  printf "%s\n" "$run_dir" > "$GUIDED_RUN_STATE_FILE"
}

clear_guided_run_override() {
  rm -f "$GUIDED_RUN_STATE_FILE"
}

collect_guided_runs() {
  local run_dir
  while IFS= read -r run_dir; do
    [[ -z "$run_dir" ]] && continue
    if [[ -f "${run_dir}/rtabmap.db" ]] || run_utils_is_trainable_run "$run_dir" || run_utils_is_viewer_ready_run "$run_dir"; then
      echo "$run_dir"
    fi
  done < <(run_utils_all_runs "$REPO_ROOT")
}

resolve_guided_run() {
  local override run_name run_dir

  if override="$(load_guided_run_override 2>/dev/null)" && [[ -d "$override" ]]; then
    printf "%s\n" "$override"
    return 0
  fi

  if run_name="$(load_last_scan_run 2>/dev/null)"; then
    run_dir="${REPO_ROOT}/runs/${run_name}"
    if [[ -d "$run_dir" ]]; then
      printf "%s\n" "$run_dir"
      return 0
    fi
  fi

  while IFS= read -r run_dir; do
    [[ -z "$run_dir" ]] && continue
    printf "%s\n" "$run_dir"
    return 0
  done < <(collect_guided_runs)

  return 0
}

guided_run_stage() {
  local run_dir="$1"
  local has_raw=0 has_db=0 has_dataset=0 has_env=0 viewer_ready=0 exported=0 train_running=0 state="" exit_code=""

  [[ -f "${run_dir}/raw/capture.mp4" ]] && has_raw=1
  [[ -f "${run_dir}/rtabmap.db" ]] && has_db=1
  [[ -f "${run_dir}/dataset/transforms.json" ]] && has_dataset=1
  [[ -f "${run_dir}/gs_input.env" ]] && has_env=1
  run_utils_is_viewer_ready_run "$run_dir" && viewer_ready=1
  [[ -f "${run_dir}/exports/splat/splat.ply" ]] && exported=1

  if [[ -f "${run_dir}/logs/train_job.pid" ]]; then
    local pid
    pid="$(cat "${run_dir}/logs/train_job.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      train_running=1
    fi
  fi

  state="$(run_utils_read_status_value "${run_dir}/logs/train_job.status" "state" || true)"
  exit_code="$(run_utils_read_status_value "${run_dir}/logs/train_job.status" "exit_code" || true)"

  echo "Selected run: ${run_dir#${REPO_ROOT}/}"
  echo ""
  [[ "$has_db" -eq 1 ]] && echo "RTAB-Map database: yes" || echo "RTAB-Map database: no"
  [[ "$has_raw" -eq 1 ]] && echo "Raw video capture: yes" || echo "Raw video capture: no"
  if [[ "$has_dataset" -eq 1 || "$has_env" -eq 1 ]]; then
    echo "Training input ready: yes"
  else
    echo "Training input ready: no"
  fi
  [[ "$train_running" -eq 1 ]] && echo "Training job running: yes" || echo "Training job running: no"
  [[ "$viewer_ready" -eq 1 ]] && echo "Browser-ready model: yes" || echo "Browser-ready model: no"
  [[ "$exported" -eq 1 ]] && echo "Exported splat file: yes" || echo "Exported splat file: no"
  if [[ "$state" == "exited" ]]; then
    echo "Last training exit code: ${exit_code:-unknown}"
  fi
  echo ""

  if [[ "$train_running" -eq 1 ]]; then
    echo "Current stage: Training is in progress"
    echo "Recommended next step: Watch training progress, then open it in the browser when finished."
  elif [[ "$viewer_ready" -eq 1 ]]; then
    echo "Current stage: Model is ready to open in a browser"
    echo "Recommended next step: Open the model in the browser."
  elif [[ "$has_dataset" -eq 1 || "$has_env" -eq 1 ]]; then
    echo "Current stage: Training input is ready"
    echo "Recommended next step: Start 3D model training."
  elif [[ "$has_db" -eq 1 || "$has_raw" -eq 1 ]]; then
    echo "Current stage: Scan data exists but it is not prepared for training yet"
    echo "Recommended next step: Prepare this run for 3D model training."
  else
    echo "Current stage: This run is missing usable scan data"
    echo "Recommended next step: Pick a different run or create one in Robot Scan or Handheld Capture."
  fi
}

run_scan_command() {
  local run_name="$1"
  shift
  save_last_scan_run "$run_name"
  clear_guided_run_override
  local -a cmd=(env RUN_NAME="$run_name" "$@")
  if [[ "$SAFE_MODE" == "1" ]]; then
    preview_command "${cmd[@]}"
    return 0
  fi
  run_in_terminal "${cmd[@]}"
}

confirm_scan_safety() {
  confirm_prompt $'Before starting motion:\n\n- Robot is on the dock or flat on the floor\n- Create 3 USB-C link is connected\n- OAK is connected\n- Floor area near the dock is clear\n- A person is nearby to supervise\n'
}

show_robot_scan_quick_guide() {
  show_info $'Use this menu if you just want to run the robot safely without learning the full project.\n\nRecommended order:\n1. Use "Run Full Scan Now" for the normal one-command workflow.\n2. Use "Prepare Scan Stack Without Motion" and then "Start Prepared Mission" only if you want to inspect everything before motion.\n3. Use "Show Robot + Scan Status" or "Dock Robot" whenever you need to check or recover the session.\n4. After the scan finishes, open "Turn Scan Into 3D Browser View" and choose "Guided Scan To Browser".\n\nSafety:\n- Keep the robot on the floor.\n- Keep the dock area and the first meter ahead clear.\n- Stay nearby while it moves.'
}

show_gaussian_plain_english_guide() {
  show_info $'This section turns an existing run into a 3D model you can open in a web browser.\n\nNormal order:\n1. Create a run with Robot Scan or Handheld Capture.\n2. Prepare that scan for training.\n3. Start training the 3D model.\n4. Open the finished model in the browser.\n\nUse "Guided Scan To Browser" if you do not know which step comes next.'
}

show_handheld_plain_english_guide() {
  show_info $'Use this section only if you want to create a new run with a handheld camera.\n\nNormal order:\n1. Check camera health.\n2. Capture a short handheld scan.\n3. Then move to Turn Scan Into 3D Browser View for training and browser viewing.'
}

do_scan_status_report() {
  run_in_terminal bash -lc '
set -euo pipefail
script_dir="$1"
repo_root="$2"
state_file="$3"

last_run="none"
if [[ -f "$state_file" ]]; then
  last_run="$(cat "$state_file")"
fi

echo "=== Robot Scan Status ==="
echo "Repo:      ${repo_root}"
echo "Last run:  ${last_run}"
echo ""
echo "--- Dock status ---"
bash "${script_dir}/robot/create3_dock_control.sh" status || true
echo ""
echo "--- Scan stack status ---"
"${script_dir}/robot/launch_live_auto_scan.sh" status || true
' _ "$SCRIPT_DIR" "$REPO_ROOT" "$STATE_FILE"
}

do_scan_history() {
  local remembered_run count line run_dir mode result has_db has_waypoints rel suffix
  remembered_run="$(current_scan_run_label)"
  count=0

  safe_clear
  echo "Previous Scan Runs"
  echo ""

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS='|' read -r run_dir mode result has_db has_waypoints <<< "$line"
    rel="${run_dir#${REPO_ROOT}/}"
    suffix=""
    if [[ "$(basename "$run_dir")" == "$remembered_run" ]]; then
      suffix=" [last prepared run]"
    fi
    count=$((count + 1))
    echo "${count}. ${rel}${suffix} | ${mode} | ${result} | rtabmap_db=${has_db} | waypoints=${has_waypoints}"
  done < <(run_utils_scan_history_lines "$REPO_ROOT")

  echo ""
  if [[ "$count" -eq 0 ]]; then
    echo "No scan runs were found yet."
  else
    echo "Total scan runs: ${count}"
  fi
  pause_terminal
}

do_robot_health_check() {
  local cmd=("${SCRIPT_DIR}/robot/create3_base_health_check.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    preview_command "${cmd[@]}"
    return 0
  fi
  run_in_terminal "${cmd[@]}"
}

do_run_full_scan_now() {
  local run_name
  run_name="$(default_scan_run_name)"
  confirm_scan_safety || return 0
  run_scan_command "$run_name" "${SCRIPT_DIR}/robot/launch_live_auto_scan.sh" start
}

do_prepare_scan_stack() {
  local run_name
  run_name="$(default_scan_run_name)"
  confirm_scan_safety || return 0
  run_scan_command "$run_name" "${SCRIPT_DIR}/robot/launch_live_auto_scan.sh" start-only
}

do_start_prepared_mission() {
  local run_name
  if ! run_name="$(load_last_scan_run 2>/dev/null)"; then
    show_info $'There is no remembered run name yet.\n\nUse "Prepare Scan Stack Without Motion" first, or use "Run Full Scan Now" for the one-command path.'
    return 0
  fi
  confirm_scan_safety || return 0
  run_scan_command "$run_name" "${SCRIPT_DIR}/robot/launch_live_auto_scan.sh" mission
}

do_dock_robot() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/create3_dock_control.sh" dock
}

do_undock_robot() {
  confirm_prompt $'Undock the robot now?\n\nMake sure the floor area ahead of the dock is clear.' || return 0
  run_robot_or_preview "${SCRIPT_DIR}/robot/create3_dock_control.sh" undock
}

do_connection_report() {
  run_in_terminal bash -lc '
set -euo pipefail
repo_root="$1"
iface="l4tbr0"
iface_state="missing"
oper="unknown"
ping_ok="no"
fw="unreachable"
docker_ok="no"

if ip link show "$iface" >/dev/null 2>&1; then
  iface_state="present"
  oper="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo unknown)"
fi

if ping -I "$iface" -c 1 -W 1 192.168.186.2 >/dev/null 2>&1; then
  ping_ok="yes"
fi

if [[ "$ping_ok" == "yes" ]]; then
  fw="$(curl --interface "$iface" -sS http://192.168.186.2/home | grep -o '\''version="[^"]*"\|rosversionname="[^"]*"'\'' | paste -sd ", " - || true)"
  fw="${fw:-reachable (metadata parse failed)}"
fi

if docker info >/dev/null 2>&1; then
  docker_ok="yes"
fi

echo "=== Create 3 USB-C connection report ==="
echo "Repo: ${repo_root}"
echo ""
echo "Interface (${iface}): ${iface_state}"
echo "Interface state:    ${oper}"
echo "Robot ping:         ${ping_ok}"
echo "Robot metadata:     ${fw}"
echo "Docker daemon:      ${docker_ok}"
echo ""
echo "Tip: For USB-C-only Create 3 control, l4tbr0 should be UP and ping should be yes."
' _ "$REPO_ROOT"
}

do_manual_drive() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/teleop_drive_app.sh"
}

do_gamecube_teleop() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/teleop_gamecube_hidraw.sh"
}

do_preflight_autonomy() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/preflight_autonomy.sh"
}

do_software_audit() {
  run_robot_or_preview "${SCRIPT_DIR}/build/software_readiness_audit.sh"
}

do_guided_nav2_start() {
  show_info $'Guided Nav2 + RTAB-Map startup (non-destructive):\n\nTerminal A:\n  ./scripts/robot/run_robot_runtime_container.sh\n  # inside container:\n  source /opt/ros/humble/setup.bash\n  # keep this shell open; use separate host shells for the wrappers below\n\nTerminal B (host):\n  ./scripts/robot/run_oak_camera.sh\n  ./scripts/robot/run_rtabmap_rgbd.sh\n\nTerminal C (host):\n  ./scripts/robot/run_nav2_with_rtabmap.sh\n\nThen send a goal:\n  ./scripts/robot/send_nav2_goal.sh 1.0 0.0 0.0 1.0\n\nNote: Keep robot on the floor in open area before sending goals.'
}

do_camera_health() {
  local cmd=("${SCRIPT_DIR}/robot/oak_camera_health_check.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_capture_handheld() {
  local duration
  duration="$(input_with_default "Capture Duration" "Seconds to record for handheld scan." "$DEFAULT_DURATION")"
  if ! is_positive_int "$duration"; then
    duration="$DEFAULT_DURATION"
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/manual_handheld_oak_capture_test.sh" --duration "$duration")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run --no-prompt)
  fi
  run_in_terminal "${cmd[@]}"
}

do_guided_status() {
  local run_dir
  run_dir="$(resolve_guided_run)"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    show_info $'No scan or training run is selected yet.\n\nRecommended next step: Create a run in Robot Scan or Handheld Capture.'
    return 0
  fi
  safe_clear
  guided_run_stage "$run_dir"
  pause_terminal
}

do_choose_guided_run() {
  local run
  run="$(select_run "guided" "Choose Guided Run" "Select the run that should move toward a browser view.")" || return 0
  save_guided_run_override "$run"
  show_info "Selected run: ${run#${REPO_ROOT}/}"
}

do_guided_prepare_run() {
  local run_dir
  run_dir="$(resolve_guided_run)"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    show_error "No guided run is selected yet."
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/prepare_gs_input_from_run.sh" --run "$run_dir")
  if [[ "$SAFE_MODE" == "1" ]]; then
    preview_command "${cmd[@]}"
    return 0
  fi
  run_in_terminal "${cmd[@]}"
}

do_guided_start_training() {
  local run_dir
  run_dir="$(resolve_guided_run)"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    show_error "No guided run is selected yet."
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/start_gaussian_training_job.sh" --run "$run_dir" --mode prep-train --max-iters "$DEFAULT_ITERS")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_guided_watch_training() {
  local run_dir
  run_dir="$(resolve_guided_run)"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    show_error "No guided run is selected yet."
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/watch_gaussian_training_job.sh" --run "$run_dir")
  if [[ "$SAFE_MODE" == "1" || "$AUTOTEST_MODE" == "1" ]]; then
    cmd+=(--no-follow --dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_guided_open_browser() {
  local run_dir
  run_dir="$(resolve_guided_run)"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    show_error "No guided run is selected yet."
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/start_gaussian_viewer.sh" --run "$run_dir" --port "$DEFAULT_PORT" --open-browser)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

guided_gaussian_menu() {
  local choice run_dir stage_line next_line selected_label
  while true; do
    run_dir="$(resolve_guided_run)"
    if [[ -n "$run_dir" && -d "$run_dir" ]]; then
      selected_label="${run_dir#${REPO_ROOT}/}"
      stage_line="$(guided_run_stage "$run_dir" | grep '^Current stage:' | head -n1 || true)"
      next_line="$(guided_run_stage "$run_dir" | grep '^Recommended next step:' | head -n1 || true)"
    else
      selected_label="none"
      stage_line="Current stage: No scan selected yet"
      next_line="Recommended next step: Create a run in Robot Scan or Handheld Capture."
    fi

    choice="$(menu_choice "Guided Scan To Browser" "Selected run: ${selected_label}\n${stage_line}\n${next_line}" \
      "1" "Show current status + recommended next step" \
      "2" "Choose which run to use" \
      "3" "Prepare selected run for training" \
      "4" "Start training for selected run" \
      "5" "Watch training progress" \
      "6" "Open selected model in browser" \
      "7" "Explain this workflow" \
      "0" "Back")"

    case "${choice:-}" in
      1) do_guided_status ;;
      2) do_choose_guided_run ;;
      3) do_guided_prepare_run ;;
      4) do_guided_start_training ;;
      5) do_guided_watch_training ;;
      6) do_guided_open_browser ;;
      7) show_gaussian_plain_english_guide ;;
      0|"") return 0 ;;
    esac
  done
}

prompt_training_mode() {
  local mode="prep-train"
  if [[ "$AUTOTEST_MODE" == "1" ]]; then
    echo "$mode"
    return 0
  fi

  if [[ "$have_whiptail" -eq 1 ]]; then
    mode="$(whiptail --title "Training Mode" --menu "Choose training mode." 14 80 4 \
      "prep-train" "Prep + train + export" \
      "train" "Train + export only" \
      "prep" "Prep only" \
      3>&1 1>&2 2>&3 || true)"
    if [[ -z "$mode" ]]; then
      mode="prep-train"
    fi
  else
    safe_clear
    echo "Training mode"
    echo "1) prep-train"
    echo "2) train"
    echo "3) prep"
    local pick
    read -rp "Choose [1]: " pick
    case "${pick:-1}" in
      1) mode="prep-train" ;;
      2) mode="train" ;;
      3) mode="prep" ;;
      *) mode="prep-train" ;;
    esac
  fi
  echo "$mode"
}

do_prep_existing_run() {
  local run
  run="$(select_run "trainable" "Prep Existing Run" "Select a trainable run.")" || return 0
  local cmd=("${SCRIPT_DIR}/gaussian/start_gaussian_training_job.sh" --run "$run" --mode prep --foreground)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_start_training() {
  local run mode iters
  run="$(select_run "trainable" "Start Training" "Select a trainable run.")" || return 0
  mode="$(prompt_training_mode)"
  iters="$(input_with_default "Training Iterations" "Set max training iterations." "$DEFAULT_ITERS")"
  if ! is_positive_int "$iters"; then
    iters="$DEFAULT_ITERS"
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/start_gaussian_training_job.sh" --run "$run" --mode "$mode" --max-iters "$iters")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_watch_logs() {
  local run
  run="$(select_run "train_logs" "Watch Logs" "Select a run with training logs.")" || return 0

  local cmd=("${SCRIPT_DIR}/gaussian/watch_gaussian_training_job.sh" --run "$run")
  if [[ "$SAFE_MODE" == "1" || "$AUTOTEST_MODE" == "1" ]]; then
    cmd+=(--no-follow --dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_training_status() {
  local run
  run="$(select_run "train_metadata" "Training Status" "Select a run with training metadata.")" || return 0
  run_in_terminal "${SCRIPT_DIR}/gaussian/training_job_status.sh" --run "$run"
}

do_stop_training() {
  local run
  run="$(select_run "train_metadata" "Stop Training" "Select a run with training metadata.")" || return 0
  local cmd=("${SCRIPT_DIR}/gaussian/stop_gaussian_training_job.sh" --run "$run")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_start_viewer() {
  local run port
  run="$(select_run "viewer_ready" "Start Viewer" "Select a viewer-ready run.")" || return 0
  port="$(input_with_default "Viewer Port" "Web viewer port." "$DEFAULT_PORT")"
  if ! is_positive_int "$port"; then
    port="$DEFAULT_PORT"
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/start_gaussian_viewer.sh" --run "$run" --port "$port")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_start_viewer_open_browser() {
  local run port
  run="$(select_run "viewer_ready" "Start Viewer + Open Browser" "Select a viewer-ready run.")" || return 0
  port="$(input_with_default "Viewer Port" "Web viewer port." "$DEFAULT_PORT")"
  if ! is_positive_int "$port"; then
    port="$DEFAULT_PORT"
  fi

  local cmd=("${SCRIPT_DIR}/gaussian/start_gaussian_viewer.sh" --run "$run" --port "$port" --open-browser)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_stop_viewer() {
  local run
  run="$(select_run "viewer_ready" "Stop Viewer" "Select the run tied to the viewer container.")" || return 0
  local cmd=("${SCRIPT_DIR}/gaussian/stop_gaussian_viewer.sh" --run "$run")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_show_exported_splats() {
  run_in_terminal bash -lc '
set -euo pipefail
repo_root="$1"
found=0
while IFS= read -r run_dir; do
  [[ -z "$run_dir" ]] && continue
  splat="${run_dir}/exports/splat/splat.ply"
  if [[ -f "$splat" ]]; then
    found=1
    printf "%s\n" "${splat#${repo_root}/}"
  fi
done < <(ls -1dt "${repo_root}"/runs/*/ 2>/dev/null | sed "s:/$::" | grep -v "/_template$" || true)
if [[ "$found" -eq 0 ]]; then
  echo "No exported splats found under runs/."
fi
' _ "$REPO_ROOT"
}

do_list_runs_badges() {
  run_in_terminal "${SCRIPT_DIR}/run_tools/list_runs.sh"
}

do_inspect_run_details() {
  local run
  run="$(select_run "any" "Inspect Run" "Select a run to inspect.")" || return 0

  run_in_terminal bash -lc '
set -euo pipefail
run_dir="$1"
repo_root="$2"
source "$3"

echo "Run: ${run_dir#${repo_root}/}"
echo "Absolute: ${run_dir}"

echo "Status badges: $(run_utils_run_status_badges "$run_dir")"

echo ""
echo "Files:"
[[ -f "$run_dir/raw/capture.mp4" ]] && echo "  raw/capture.mp4: yes" || echo "  raw/capture.mp4: no"
[[ -f "$run_dir/gs_input.env" ]] && echo "  gs_input.env: yes" || echo "  gs_input.env: no"
[[ -f "$run_dir/exports/splat/splat.ply" ]] && echo "  exports/splat/splat.ply: yes" || echo "  exports/splat/splat.ply: no"

config_count="$(find "$run_dir/checkpoints" -name config.yml 2>/dev/null | wc -l | tr -d " ")"
echo "  checkpoints config.yml count: ${config_count}"

if [[ -f "$run_dir/logs/train_job.status" || -f "$run_dir/logs/train_job.pid" || -L "$run_dir/logs/train_job.latest.log" || -f "$run_dir/logs/train_job.latest.log" ]]; then
  echo ""
  "$repo_root/scripts/gaussian/training_job_status.sh" --run "$run_dir"
else
  echo ""
  echo "No training metadata/logs found for this run."
fi
' _ "$run" "$REPO_ROOT" "${SCRIPT_DIR}/lib/_run_utils.sh"
}

do_delete_run() {
  local run
  run="$(select_run "any" "Delete Run" "Select a run to move to trash.")" || return 0

  if ! confirm_prompt "Move ${run#${REPO_ROOT}/} to runs/.trash?"; then
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/run_tools/delete_run.sh" --run "$run" --yes)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_restore_run() {
  local entry
  entry="$(select_trash_entry)" || return 0

  local cmd=("${SCRIPT_DIR}/run_tools/restore_run.sh" --entry "$entry")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_purge_trash() {
  local days
  days="$(input_with_default "Purge Trash" "Delete trash entries older than how many days?" "$DEFAULT_DAYS")"
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    days="$DEFAULT_DAYS"
  fi

  if ! confirm_prompt "Permanently purge trash entries older than ${days} days?"; then
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/run_tools/purge_run_trash.sh" --older-than-days "$days")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_build_training_cached() {
  local cmd=("${SCRIPT_DIR}/build/build_jetson_training_images.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_validate_training_clean() {
  local cmd=("${SCRIPT_DIR}/build/validate_docker_builds.sh" --mode clean --target training)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_build_rtabmap_image() {
  local cmd=("${SCRIPT_DIR}/build/build_robot_runtime_image.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    preview_command "${cmd[@]}"
    return 0
  fi
  run_in_terminal "${cmd[@]}"
}

do_validate_all_builds() {
  local cmd=("${SCRIPT_DIR}/build/validate_docker_builds.sh" --mode cached --target all)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

run_robot_or_preview() {
  local -a cmd=("$@")
  if [[ "$SAFE_MODE" == "1" ]]; then
    preview_command "${cmd[@]}"
    return 0
  fi
  run_in_terminal "${cmd[@]}"
}

do_run_rtabmap_container() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/run_robot_runtime_container.sh"
}

do_run_oak_ros_camera() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/run_oak_camera.sh"
}

do_run_rtabmap_rgbd() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/run_rtabmap_rgbd.sh"
}

do_record_raw_bag() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/record_raw_bag.sh"
}

do_run_nav2_with_rtabmap() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/run_nav2_with_rtabmap.sh"
}

do_send_nav2_goal() {
  local x y qz qw
  x="$(input_with_default "Nav2 Goal" "Goal X coordinate." "0.0")"
  y="$(input_with_default "Nav2 Goal" "Goal Y coordinate." "0.0")"
  qz="$(input_with_default "Nav2 Goal" "Goal orientation qz." "0.0")"
  qw="$(input_with_default "Nav2 Goal" "Goal orientation qw." "1.0")"

  run_robot_or_preview "${SCRIPT_DIR}/robot/send_nav2_goal.sh" "$x" "$y" "$qz" "$qw"
}

do_teleop_keyboard() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/teleop_keyboard.sh"
}

do_teleop_arrows() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/teleop_arrow_keys.sh"
}

do_ros_health_check() {
  run_robot_or_preview "${SCRIPT_DIR}/robot/ros_health_check.sh"
}

do_self_test() {
  run_in_terminal bash -lc '
set -euo pipefail
cd "$1"
./scripts/tests/test_operator_tuis.sh
echo ""
./scripts/tests/test_gs_tui.sh
' _ "$REPO_ROOT"
}

do_show_docker_status() {
  run_in_terminal bash -lc '
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found"
  exit 1
fi

docker info | sed -n "1,80p"
echo ""
echo "Container summary:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
'
}

do_show_viewer_containers() {
  run_in_terminal bash -lc '
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found"
  exit 1
fi

docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | {
  read -r header || true
  echo "$header"
  grep "gs_viewer_" || true
}
'
}

do_cleanup_stale_training_state() {
  local cmd=("${SCRIPT_DIR}/gaussian/cleanup_stale_training_state.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

menu_gaussian_workflow() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Turn Scan Into 3D Browser View" "Use this after you already have a run. This section prepares, trains, and opens the 3D model." \
      "1" "Guided Scan To Browser (recommended)" \
      "2" "Prep existing run" \
      "3" "Start training" \
      "4" "Watch logs" \
      "5" "Training status" \
      "6" "Stop training" \
      "7" "Start viewer + open browser" \
      "8" "Start viewer" \
      "9" "Stop viewer" \
      "10" "Show exported splat paths" \
      "11" "Explain workflow in plain English" \
      "0" "Back")"

    case "$choice" in
      1) guided_gaussian_menu ;;
      2) do_prep_existing_run ;;
      3) do_start_training ;;
      4) do_watch_logs ;;
      5) do_training_status ;;
      6) do_stop_training ;;
      7) do_start_viewer_open_browser ;;
      8) do_start_viewer ;;
      9) do_stop_viewer ;;
      10) do_show_exported_splats ;;
      11) show_gaussian_plain_english_guide ;;
      0|"") return 0 ;;
      *) ;;
    esac
  done
}

menu_handheld_capture() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Handheld Capture" "Create a new run with a handheld camera. Training and browser viewing happen later." \
      "1" "Camera health check" \
      "2" "Capture handheld scan" \
      "3" "Explain handheld capture" \
      "0" "Back")"

    case "$choice" in
      1) do_camera_health ;;
      2) do_capture_handheld ;;
      3) show_handheld_plain_english_guide ;;
      0|"") return 0 ;;
      *) ;;
    esac
  done
}

menu_robot_scan() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Robot Scan" "Recommended path for supervised scan sessions. Last prepared run: $(current_scan_run_label)" \
      "1" "Run Full Scan Now (recommended)" \
      "2" "Prepare Scan Stack Without Motion" \
      "3" "Start Prepared Mission" \
      "4" "Show Robot + Scan Status" \
      "5" "List Previous Scan Runs" \
      "6" "Dock Robot" \
      "7" "Undock Robot" \
      "8" "Show Quick Guide" \
      "0" "Back")"

    case "$choice" in
      1) do_run_full_scan_now ;;
      2) do_prepare_scan_stack ;;
      3) do_start_prepared_mission ;;
      4) do_scan_status_report ;;
      5) do_scan_history ;;
      6) do_dock_robot ;;
      7) do_undock_robot ;;
      8) show_robot_scan_quick_guide ;;
      0|"") return 0 ;;
      *) ;;
    esac
  done
}

menu_run_management() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Run Management" "Choose an action." \
      "1" "List runs with status badges" \
      "2" "Inspect run details" \
      "3" "Delete run (soft delete)" \
      "4" "Restore deleted run" \
      "5" "Purge trash older than N days" \
      "0" "Back")"

    case "$choice" in
      1) do_list_runs_badges ;;
      2) do_inspect_run_details ;;
      3) do_delete_run ;;
      4) do_restore_run ;;
      5) do_purge_trash ;;
      0|"") return 0 ;;
      *) ;;
    esac
  done
}

menu_builds() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Builds" "Choose an action." \
      "1" "Build training images (cached)" \
      "2" "Validate training builds (clean)" \
      "3" "Build RTAB-Map image" \
      "4" "Validate all builds" \
      "0" "Back")"

    case "$choice" in
      1) do_build_training_cached ;;
      2) do_validate_training_clean ;;
      3) do_build_rtabmap_image ;;
      4) do_validate_all_builds ;;
      0|"") return 0 ;;
      *) ;;
    esac
  done
}

menu_robot_tools() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Robot Tools" "Advanced robot bringup, teleop, and diagnostics." \
      "1" "Check robot USB-C link" \
      "2" "Run robot health check" \
      "3" "Manual drive app" \
      "4" "GameCube controller teleop" \
      "5" "Arrow-key teleop" \
      "6" "Keyboard teleop" \
      "7" "ROS health check" \
      "8" "Autonomy preflight" \
      "9" "Software readiness audit" \
      "10" "Guided Nav2 + scan startup notes" \
      "11" "Run robot runtime container" \
      "12" "Run OAK ROS camera" \
      "13" "Run RTAB-Map RGBD" \
      "14" "Record raw bag" \
      "15" "Run Nav2 with RTAB-Map" \
      "16" "Send Nav2 goal" \
      "0" "Back")"

    case "$choice" in
      1) do_connection_report ;;
      2) do_robot_health_check ;;
      3) do_manual_drive ;;
      4) do_gamecube_teleop ;;
      5) do_teleop_arrows ;;
      6) do_teleop_keyboard ;;
      7) do_ros_health_check ;;
      8) do_preflight_autonomy ;;
      9) do_software_audit ;;
      10) do_guided_nav2_start ;;
      11) do_run_rtabmap_container ;;
      12) do_run_oak_ros_camera ;;
      13) do_run_rtabmap_rgbd ;;
      14) do_record_raw_bag ;;
      15) do_run_nav2_with_rtabmap ;;
      16) do_send_nav2_goal ;;
      0|"") return 0 ;;
      *) ;;
    esac
  done
}

menu_diagnostics() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Diagnostics" "Choose an action." \
      "1" "Run TUI self-test" \
      "2" "Show Docker runtime status" \
      "3" "Show viewer containers" \
      "4" "Cleanup stale training pid/status" \
      "0" "Back")"

    case "$choice" in
      1) do_self_test ;;
      2) do_show_docker_status ;;
      3) do_show_viewer_containers ;;
      4) do_cleanup_stale_training_state ;;
      0|"") return 0 ;;
      *) ;;
    esac
  done
}

main_menu() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "GassianRobot Master TUI" "One menu for robot scan, robot tools, handheld capture, scan-to-browser processing, runs, builds, and diagnostics." \
      "1" "Robot scan (recommended)" \
      "2" "Robot tools" \
      "3" "Handheld capture" \
      "4" "Turn scan into 3D browser view" \
      "5" "Run management" \
      "6" "Builds" \
      "7" "Diagnostics" \
      "0" "Exit")"

    case "$choice" in
      1) menu_robot_scan ;;
      2) menu_robot_tools ;;
      3) menu_handheld_capture ;;
      4) menu_gaussian_workflow ;;
      5) menu_run_management ;;
      6) menu_builds ;;
      7) menu_diagnostics ;;
      0|"") safe_clear; exit 0 ;;
      *) ;;
    esac
  done
}

if [[ "$SELF_TEST_ONLY" -eq 1 ]]; then
  do_self_test
  exit 0
fi

case "$START_SECTION" in
  robot-scan)
    menu_robot_scan
    ;;
  robot-tools)
    menu_robot_tools
    ;;
  handheld)
    menu_handheld_capture
    ;;
  gaussian)
    menu_gaussian_workflow
    ;;
  runs)
    menu_run_management
    ;;
  builds)
    menu_builds
    ;;
  diagnostics)
    menu_diagnostics
    ;;
  "")
    ;;
  *)
    show_error "Unknown start section: ${START_SECTION}"
    ;;
esac

main_menu
