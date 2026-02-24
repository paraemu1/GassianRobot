#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_ITERS=30000
DEFAULT_PORT=7007
DEFAULT_DURATION=20

usage() {
  cat <<'EOF'
Gaussian Splat TUI launcher.

Usage:
  ./scripts/gs_tui.sh

This opens an interactive menu to run capture, training, logs, and viewer tasks.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

have_whiptail=0
if command -v whiptail >/dev/null 2>&1; then
  have_whiptail=1
fi

pause_terminal() {
  echo ""
  read -rp "Press Enter to return to the menu... " _
}

run_in_terminal() {
  clear
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

input_with_default_plain() {
  local prompt="$1"
  local def="$2"
  local out
  read -rp "${prompt} [${def}]: " out
  if [[ -z "$out" ]]; then
    echo "$def"
  else
    echo "$out"
  fi
}

confirm_plain() {
  local prompt="$1"
  local ans
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

is_positive_int() {
  local v="$1"
  [[ "$v" =~ ^[1-9][0-9]*$ ]]
}

prompt_iters() {
  local iters
  if [[ "$have_whiptail" -eq 1 ]]; then
    iters="$(whiptail --title "Training Iterations" --inputbox "Set max iterations." 10 70 "${DEFAULT_ITERS}" 3>&1 1>&2 2>&3 || true)"
  else
    iters="$(input_with_default_plain "Set max iterations" "${DEFAULT_ITERS}")"
  fi
  if ! is_positive_int "${iters}"; then
    iters="${DEFAULT_ITERS}"
  fi
  echo "${iters}"
}

prompt_duration() {
  local dur
  if [[ "$have_whiptail" -eq 1 ]]; then
    dur="$(whiptail --title "Capture Duration" --inputbox "Seconds to record for manual handheld capture." 10 70 "${DEFAULT_DURATION}" 3>&1 1>&2 2>&3 || true)"
  else
    dur="$(input_with_default_plain "Capture duration seconds" "${DEFAULT_DURATION}")"
  fi
  if ! is_positive_int "${dur}"; then
    dur="${DEFAULT_DURATION}"
  fi
  echo "${dur}"
}

prompt_port() {
  local port
  if [[ "$have_whiptail" -eq 1 ]]; then
    port="$(whiptail --title "Viewer Port" --inputbox "Web viewer port." 10 70 "${DEFAULT_PORT}" 3>&1 1>&2 2>&3 || true)"
  else
    port="$(input_with_default_plain "Viewer port" "${DEFAULT_PORT}")"
  fi
  if ! is_positive_int "${port}"; then
    port="${DEFAULT_PORT}"
  fi
  echo "${port}"
}

prompt_mode() {
  local mode="prep-train"
  if [[ "$have_whiptail" -eq 1 ]]; then
    mode="$(whiptail --title "Training Mode" --menu "Choose mode." 14 72 4 \
      "prep-train" "Prep + train + export (Recommended)" \
      "train" "Train + export only (skip prep)" \
      "prep" "Prep only (no training)" \
      3>&1 1>&2 2>&3 || true)"
    if [[ -z "$mode" ]]; then
      mode="prep-train"
    fi
  else
    echo "Training mode:"
    echo "  1) prep-train (recommended)"
    echo "  2) train"
    echo "  3) prep"
    local choice
    read -rp "Choose [1]: " choice
    case "${choice:-1}" in
      1) mode="prep-train" ;;
      2) mode="train" ;;
      3) mode="prep" ;;
      *) mode="prep-train" ;;
    esac
  fi
  echo "${mode}"
}

show_info() {
  local msg="$1"
  if [[ "$have_whiptail" -eq 1 ]]; then
    whiptail --title "Info" --msgbox "$msg" 12 76
  else
    echo "$msg"
    pause_terminal
  fi
}

do_camera_check() {
  run_in_terminal "${SCRIPT_DIR}/oak_camera_health_check.sh"
}

do_capture_new_scan() {
  local duration
  duration="$(prompt_duration)"
  run_in_terminal "${SCRIPT_DIR}/manual_handheld_oak_capture_test.sh" --duration "${duration}"
  if [[ "$have_whiptail" -eq 1 ]]; then
    if whiptail --title "Start Training?" --yesno "Capture finished. Start training on latest run now?" 10 72; then
      do_start_training_latest
    fi
  else
    if confirm_plain "Capture finished. Start training on latest run now?"; then
      do_start_training_latest
    fi
  fi
}

do_start_training_latest() {
  local mode iters
  mode="$(prompt_mode)"
  iters="$(prompt_iters)"
  run_in_terminal "${SCRIPT_DIR}/start_gaussian_training_job.sh" --run latest --mode "${mode}" --max-iters "${iters}"
}

do_watch_logs() {
  show_info "Watching latest training logs.\nPress Ctrl+C to stop watching and return to menu."
  run_in_terminal "${SCRIPT_DIR}/watch_gaussian_training_job.sh" --run latest
}

do_stop_training() {
  run_in_terminal "${SCRIPT_DIR}/stop_gaussian_training_job.sh" --run latest
}

do_start_viewer() {
  local port
  port="$(prompt_port)"
  run_in_terminal "${SCRIPT_DIR}/start_gaussian_viewer.sh" --run latest --port "${port}"
}

do_stop_viewer() {
  run_in_terminal "${SCRIPT_DIR}/stop_gaussian_viewer.sh" --run latest
}

do_list_runs() {
  run_in_terminal "${SCRIPT_DIR}/list_runs.sh"
}

do_build_images() {
  if [[ "$have_whiptail" -eq 1 ]]; then
    if ! whiptail --title "Build Images" --yesno "Build training images now? This can take a long time." 10 74; then
      return 0
    fi
  else
    if ! confirm_plain "Build training images now? This can take a long time."; then
      return 0
    fi
  fi
  run_in_terminal "${SCRIPT_DIR}/build_jetson_training_images.sh"
}

do_open_guide() {
  run_in_terminal bash -lc "cd '${REPO_ROOT}' && if command -v less >/dev/null 2>&1; then less docs/guides/GETTING_STARTED_GAUSSIAN_SPLATS.md; else cat docs/guides/GETTING_STARTED_GAUSSIAN_SPLATS.md; fi"
}

menu_whiptail() {
  while true; do
    local choice
    choice="$(whiptail --title "Gaussian Splat Easy Menu" --menu "Pick what you want to do." 22 86 12 \
      "1" "NEW SCAN (capture with camera)" \
      "2" "Start training (latest run)" \
      "3" "Watch training logs" \
      "4" "Stop training" \
      "5" "Start web viewer" \
      "6" "Stop web viewer" \
      "7" "Camera health check" \
      "8" "List runs" \
      "9" "Build/repair training images" \
      "10" "Open beginner guide" \
      "0" "Exit" \
      3>&1 1>&2 2>&3 || true)"

    case "$choice" in
      1) do_capture_new_scan ;;
      2) do_start_training_latest ;;
      3) do_watch_logs ;;
      4) do_stop_training ;;
      5) do_start_viewer ;;
      6) do_stop_viewer ;;
      7) do_camera_check ;;
      8) do_list_runs ;;
      9) do_build_images ;;
      10) do_open_guide ;;
      0|"") clear; exit 0 ;;
      *) ;;
    esac
  done
}

menu_plain() {
  while true; do
    clear
    echo "Gaussian Splat Easy Menu"
    echo "Repo: ${REPO_ROOT}"
    echo ""
    echo "1) NEW SCAN (capture with camera)"
    echo "2) Start training (latest run)"
    echo "3) Watch training logs"
    echo "4) Stop training"
    echo "5) Start web viewer"
    echo "6) Stop web viewer"
    echo "7) Camera health check"
    echo "8) List runs"
    echo "9) Build/repair training images"
    echo "10) Open beginner guide"
    echo "0) Exit"
    echo ""
    local choice
    read -rp "Choose: " choice
    case "$choice" in
      1) do_capture_new_scan ;;
      2) do_start_training_latest ;;
      3) do_watch_logs ;;
      4) do_stop_training ;;
      5) do_start_viewer ;;
      6) do_stop_viewer ;;
      7) do_camera_check ;;
      8) do_list_runs ;;
      9) do_build_images ;;
      10) do_open_guide ;;
      0) clear; exit 0 ;;
      *) echo "Invalid choice."; pause_terminal ;;
    esac
  done
}

if [[ "$have_whiptail" -eq 1 ]]; then
  menu_whiptail
else
  menu_plain
fi
