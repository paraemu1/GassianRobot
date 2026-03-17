#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

DEFAULT_ITERS=30000
DEFAULT_PORT=7007
DEFAULT_DURATION=20
DEFAULT_DAYS=30
SAFE_MODE="${GS_TUI_SAFE_MODE:-0}"
FORCE_PLAIN=0
AUTOTEST_MODE="${GS_TUI_AUTOTEST:-0}"
SELF_TEST_ONLY=0

usage() {
  cat <<'USAGE'
Full workflow TUI launcher.

Usage:
  ./scripts/gs_tui.sh [--force-plain] [--safe-mode]
  ./scripts/gs_tui.sh --self-test

Options:
  --force-plain  Disable whiptail and use plain text menus.
  --safe-mode    Use dry-run mode for supported actions.
  --self-test    Run the non-destructive TUI test suite and exit.
  -h, --help     Show this help.

Environment:
  GS_TUI_SAFE_MODE=1   Same as --safe-mode.
  GS_TUI_AUTOTEST=1    Skip pauses/prompts for automation.
  GS_TUI_FORCE_PLAIN=1 Same as --force-plain.
USAGE
}

if [[ "${GS_TUI_FORCE_PLAIN:-0}" == "1" ]]; then
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

do_camera_health() {
  local cmd=("${SCRIPT_DIR}/oak_camera_health_check.sh")
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

  local cmd=("${SCRIPT_DIR}/manual_handheld_oak_capture_test.sh" --duration "$duration")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run --no-prompt)
  fi
  run_in_terminal "${cmd[@]}"
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
  local cmd=("${SCRIPT_DIR}/start_gaussian_training_job.sh" --run "$run" --mode prep --foreground)
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

  local cmd=("${SCRIPT_DIR}/start_gaussian_training_job.sh" --run "$run" --mode "$mode" --max-iters "$iters")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_watch_logs() {
  local run
  run="$(select_run "train_logs" "Watch Logs" "Select a run with training logs.")" || return 0

  local cmd=("${SCRIPT_DIR}/watch_gaussian_training_job.sh" --run "$run")
  if [[ "$SAFE_MODE" == "1" || "$AUTOTEST_MODE" == "1" ]]; then
    cmd+=(--no-follow --dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_training_status() {
  local run
  run="$(select_run "train_metadata" "Training Status" "Select a run with training metadata.")" || return 0
  run_in_terminal "${SCRIPT_DIR}/training_job_status.sh" --run "$run"
}

do_stop_training() {
  local run
  run="$(select_run "train_metadata" "Stop Training" "Select a run with training metadata.")" || return 0
  local cmd=("${SCRIPT_DIR}/stop_gaussian_training_job.sh" --run "$run")
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

  local cmd=("${SCRIPT_DIR}/start_gaussian_viewer.sh" --run "$run" --port "$port")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_stop_viewer() {
  local run
  run="$(select_run "viewer_ready" "Stop Viewer" "Select the run tied to the viewer container.")" || return 0
  local cmd=("${SCRIPT_DIR}/stop_gaussian_viewer.sh" --run "$run")
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
  run_in_terminal "${SCRIPT_DIR}/list_runs.sh"
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
  "$repo_root/scripts/training_job_status.sh" --run "$run_dir"
else
  echo ""
  echo "No training metadata/logs found for this run."
fi
' _ "$run" "$REPO_ROOT" "${SCRIPT_DIR}/_run_utils.sh"
}

do_delete_run() {
  local run
  run="$(select_run "any" "Delete Run" "Select a run to move to trash.")" || return 0

  if ! confirm_prompt "Move ${run#${REPO_ROOT}/} to runs/.trash?"; then
    return 0
  fi

  local cmd=("${SCRIPT_DIR}/delete_run.sh" --run "$run" --yes)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_restore_run() {
  local entry
  entry="$(select_trash_entry)" || return 0

  local cmd=("${SCRIPT_DIR}/restore_run.sh" --entry "$entry")
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

  local cmd=("${SCRIPT_DIR}/purge_run_trash.sh" --older-than-days "$days")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_build_training_cached() {
  local cmd=("${SCRIPT_DIR}/build_jetson_training_images.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_validate_training_clean() {
  local cmd=("${SCRIPT_DIR}/validate_docker_builds.sh" --mode clean --target training)
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

do_build_rtabmap_image() {
  local cmd=("${SCRIPT_DIR}/build_rtabmap_image.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    preview_command "${cmd[@]}"
    return 0
  fi
  run_in_terminal "${cmd[@]}"
}

do_validate_all_builds() {
  local cmd=("${SCRIPT_DIR}/validate_docker_builds.sh" --mode cached --target all)
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
  run_robot_or_preview "${SCRIPT_DIR}/run_rtabmap_container.sh"
}

do_run_oak_ros_camera() {
  run_robot_or_preview "${SCRIPT_DIR}/run_oak_camera.sh"
}

do_run_rtabmap_rgbd() {
  run_robot_or_preview "${SCRIPT_DIR}/run_rtabmap_rgbd.sh"
}

do_record_raw_bag() {
  run_robot_or_preview "${SCRIPT_DIR}/record_raw_bag.sh"
}

do_run_nav2_with_rtabmap() {
  run_robot_or_preview "${SCRIPT_DIR}/run_nav2_with_rtabmap.sh"
}

do_send_nav2_goal() {
  local x y qz qw
  x="$(input_with_default "Nav2 Goal" "Goal X coordinate." "0.0")"
  y="$(input_with_default "Nav2 Goal" "Goal Y coordinate." "0.0")"
  qz="$(input_with_default "Nav2 Goal" "Goal orientation qz." "0.0")"
  qw="$(input_with_default "Nav2 Goal" "Goal orientation qw." "1.0")"

  run_robot_or_preview "${SCRIPT_DIR}/send_nav2_goal.sh" "$x" "$y" "$qz" "$qw"
}

do_teleop_keyboard() {
  run_robot_or_preview "${SCRIPT_DIR}/teleop_keyboard.sh"
}

do_teleop_arrows() {
  run_robot_or_preview "${SCRIPT_DIR}/teleop_arrow_keys.sh"
}

do_ros_health_check() {
  run_robot_or_preview "${SCRIPT_DIR}/ros_health_check.sh"
}

do_self_test() {
  run_in_terminal "${SCRIPT_DIR}/test_gs_tui.sh"
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
  local cmd=("${SCRIPT_DIR}/cleanup_stale_training_state.sh")
  if [[ "$SAFE_MODE" == "1" ]]; then
    cmd+=(--dry-run)
  fi
  run_in_terminal "${cmd[@]}"
}

menu_gaussian_workflow() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Gaussian Workflow" "Choose an action." \
      "1" "Camera health check" \
      "2" "Capture handheld scan" \
      "3" "Prep existing run" \
      "4" "Start training" \
      "5" "Watch logs" \
      "6" "Training status" \
      "7" "Stop training" \
      "8" "Start viewer" \
      "9" "Stop viewer" \
      "10" "Show exported splat paths" \
      "0" "Back")"

    case "$choice" in
      1) do_camera_health ;;
      2) do_capture_handheld ;;
      3) do_prep_existing_run ;;
      4) do_start_training ;;
      5) do_watch_logs ;;
      6) do_training_status ;;
      7) do_stop_training ;;
      8) do_start_viewer ;;
      9) do_stop_viewer ;;
      10) do_show_exported_splats ;;
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

menu_docker_environment() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "Docker & Environment" "Choose an action." \
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

menu_robot_ops() {
  while true; do
    safe_clear
    local choice
    choice="$(menu_choice "RTAB-Map / Nav2 / Robot Ops" "Choose an action." \
      "1" "Run RTAB-Map container" \
      "2" "Run OAK ROS camera" \
      "3" "Run RTAB-Map RGBD" \
      "4" "Record raw bag" \
      "5" "Run Nav2 with RTAB-Map" \
      "6" "Send Nav2 goal" \
      "7" "Teleop keyboard" \
      "8" "Teleop arrows" \
      "9" "ROS health check" \
      "0" "Back")"

    case "$choice" in
      1) do_run_rtabmap_container ;;
      2) do_run_oak_ros_camera ;;
      3) do_run_rtabmap_rgbd ;;
      4) do_record_raw_bag ;;
      5) do_run_nav2_with_rtabmap ;;
      6) do_send_nav2_goal ;;
      7) do_teleop_keyboard ;;
      8) do_teleop_arrows ;;
      9) do_ros_health_check ;;
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
    choice="$(menu_choice "Project Workflow TUI" "Select a workflow area." \
      "1" "Gaussian workflow" \
      "2" "Run management" \
      "3" "Docker & environment" \
      "4" "RTAB-Map / Nav2 / robot ops" \
      "5" "Diagnostics" \
      "0" "Exit")"

    case "$choice" in
      1) menu_gaussian_workflow ;;
      2) menu_run_management ;;
      3) menu_docker_environment ;;
      4) menu_robot_ops ;;
      5) menu_diagnostics ;;
      0|"") safe_clear; exit 0 ;;
      *) ;;
    esac
  done
}

if [[ "$SELF_TEST_ONLY" -eq 1 ]]; then
  do_self_test
  exit 0
fi

main_menu
