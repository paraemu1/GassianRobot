#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TUI_SCRIPT="${SCRIPT_DIR}/../gs_tui.sh"
KEEP_RUN=0

usage() {
  cat <<'USAGE'
Run non-destructive checks for the full workflow TUI.

Usage:
  ./scripts/tests/test_gs_tui.sh [--keep-run]

Options:
  --keep-run  Keep temporary self-test run folders under runs/.
  -h, --help  Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-run)
      KEEP_RUN=1
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

if [[ ! -x "$TUI_SCRIPT" ]]; then
  echo "TUI script not found or not executable: $TUI_SCRIPT" >&2
  exit 1
fi

timestamp="$(date +%H%M%S)"
scene_main="_tui_selftest_${timestamp}"
scene_delete="_tui_delete_restore_${timestamp}"
run_dir_main="${REPO_ROOT}/runs/$(date +%F)-${scene_main}"
run_dir_delete="${REPO_ROOT}/runs/$(date +%F)-${scene_delete}"

failures=0
passes=0

cleanup() {
  if [[ "$KEEP_RUN" -eq 1 ]]; then
    return 0
  fi

  rm -rf "$run_dir_main" "$run_dir_delete"
  rm -rf "${REPO_ROOT}/scripts/runs"
}
trap cleanup EXIT

run_step() {
  local label="$1"
  shift
  local out_file
  out_file="$(mktemp)"
  if "$@" >"$out_file" 2>&1; then
    echo "[PASS] $label"
    passes=$((passes + 1))
  else
    echo "[FAIL] $label"
    cat "$out_file"
    failures=$((failures + 1))
  fi
  rm -f "$out_file"
}

run_step_expect() {
  local label="$1"
  local pattern="$2"
  shift 2
  local out_file
  out_file="$(mktemp)"
  if "$@" >"$out_file" 2>&1 && grep -Eq "$pattern" "$out_file"; then
    echo "[PASS] $label"
    passes=$((passes + 1))
  else
    echo "[FAIL] $label"
    cat "$out_file"
    failures=$((failures + 1))
  fi
  rm -f "$out_file"
}

run_step_not_expect() {
  local label="$1"
  local pattern="$2"
  shift 2
  local out_file
  out_file="$(mktemp)"
  if "$@" >"$out_file" 2>&1 && ! grep -Eq "$pattern" "$out_file"; then
    echo "[PASS] $label"
    passes=$((passes + 1))
  else
    echo "[FAIL] $label"
    cat "$out_file"
    failures=$((failures + 1))
  fi
  rm -f "$out_file"
}

run_tui_sequence() {
  local label="$1"
  local sequence="$2"
  local out_file
  out_file="$(mktemp)"
  if printf "%b" "$sequence" | GS_TUI_FORCE_PLAIN=1 GS_TUI_SAFE_MODE=1 GS_TUI_AUTOTEST=1 "$TUI_SCRIPT" >"$out_file" 2>&1; then
    echo "[PASS] $label"
    passes=$((passes + 1))
  else
    echo "[FAIL] $label"
    cat "$out_file"
    failures=$((failures + 1))
  fi
  rm -f "$out_file"
}

create_fixture_run() {
  local scene="$1"
  local run_dir="$2"

  RUN_ROOT="${REPO_ROOT}/runs" "${SCRIPT_DIR}/../run_tools/init_run_dir.sh" "$scene" >/dev/null
  mkdir -p "${run_dir}/logs" "${run_dir}/raw" "${run_dir}/checkpoints/selftest" "${run_dir}/exports/splat"

  touch "${run_dir}/raw/capture.mp4"
  cat > "${run_dir}/gs_input.env" <<'ENV'
VIDEO_PATH=/tmp/fake.mp4
ENV
  cat > "${run_dir}/checkpoints/selftest/config.yml" <<'CFG'
experiment_name: tui-self-test
CFG
  touch "${run_dir}/exports/splat/splat.ply"

  local log_file
  log_file="${run_dir}/logs/train_job_$(date +%F_%H%M%S).log"
  cat >"$log_file" <<'LOG'
self-test training log placeholder
LOG
  ln -sfn "$(basename "$log_file")" "${run_dir}/logs/train_job.latest.log"
  cat > "${run_dir}/logs/train_job.status" <<'STATUS'
state=exited
run_dir=/tmp/placeholder
pid=999999
started_at=2026-01-01T00:00:00+00:00
ended_at=2026-01-01T00:10:00+00:00
exit_code=0
mode=prep-train
log_file=/tmp/placeholder.log
launcher=/tmp/placeholder.sh
STATUS
  echo "999999" > "${run_dir}/logs/train_job.pid"

  touch "$run_dir"
}

echo "Creating fixture runs under ${REPO_ROOT}/runs"
create_fixture_run "$scene_main" "$run_dir_main"
create_fixture_run "$scene_delete" "$run_dir_delete"

# Make camera_health newer so latest(any) differs from latest(trainable) logic.
mkdir -p "${REPO_ROOT}/runs/camera_health"
touch "${REPO_ROOT}/runs/camera_health"

run_step "TUI help renders" "$TUI_SCRIPT" --help
run_step "Build training images dry-run with passthrough flags" "${SCRIPT_DIR}/../build/build_jetson_training_images.sh" --dry-run --no-cache --pull --progress plain
run_step "Validate docker builds dry-run" "${SCRIPT_DIR}/../build/validate_docker_builds.sh" --mode clean --target all --dry-run
run_step "Training status works on explicit run" "${SCRIPT_DIR}/../gaussian/training_job_status.sh" --run "$run_dir_main"

run_step_not_expect "Latest training run excludes camera_health" "camera_health" "${SCRIPT_DIR}/../gaussian/start_gaussian_training_job.sh" --run latest --dry-run
run_step_not_expect "Latest viewer run excludes camera_health" "camera_health" "${SCRIPT_DIR}/../gaussian/start_gaussian_viewer.sh" --run latest --dry-run
run_step_expect "Watch logs resolves latest train log run" "Run:" "${SCRIPT_DIR}/../gaussian/watch_gaussian_training_job.sh" --run latest --dry-run --no-follow

run_step "Delete run soft-delete flow" "${SCRIPT_DIR}/../run_tools/delete_run.sh" --run "$run_dir_delete" --yes

trash_entry="$(ls -1dt "${REPO_ROOT}/runs/.trash"/*/ 2>/dev/null | sed 's:/$::' | grep -- "-$(basename "$run_dir_delete")$" | head -n1 || true)"
if [[ -z "$trash_entry" ]]; then
  echo "[FAIL] Restore run flow setup"
  failures=$((failures + 1))
else
  run_step "Restore run flow" "${SCRIPT_DIR}/../run_tools/restore_run.sh" --entry "$(basename "$trash_entry")"
fi

run_step "Purge trash dry-run" "${SCRIPT_DIR}/../run_tools/purge_run_trash.sh" --older-than-days 0 --dry-run
run_step "Cleanup stale training state dry-run" "${SCRIPT_DIR}/../gaussian/cleanup_stale_training_state.sh" --dry-run

# Gaussian workflow menu actions (safe mode)
run_tui_sequence "TUI Gaussian: camera health" "1\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: capture handheld" "1\n2\n0\n0\n"
run_tui_sequence "TUI Gaussian: prep existing run" "1\n3\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: start training" "1\n4\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: watch logs" "1\n5\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: training status" "1\n6\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: stop training" "1\n7\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: start viewer" "1\n8\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: stop viewer" "1\n9\n1\n0\n0\n"
run_tui_sequence "TUI Gaussian: show exported splats" "1\n10\n0\n0\n"

# Run management menu actions (safe mode)
run_tui_sequence "TUI Runs: list with badges" "2\n1\n0\n0\n"
run_tui_sequence "TUI Runs: inspect details" "2\n2\n1\n0\n0\n"
run_tui_sequence "TUI Runs: delete run dry-run" "2\n3\n1\n0\n0\n"
run_tui_sequence "TUI Runs: purge trash" "2\n5\n0\n0\n"

# Docker/environment menu actions (safe mode)
run_tui_sequence "TUI Docker: build training cached" "3\n1\n0\n0\n"
run_tui_sequence "TUI Docker: validate training clean" "3\n2\n0\n0\n"
run_tui_sequence "TUI Docker: build rtabmap" "3\n3\n0\n0\n"
run_tui_sequence "TUI Docker: validate all" "3\n4\n0\n0\n"

# Robot ops menu actions (safe mode preview)
run_tui_sequence "TUI Robot: run rtabmap container" "4\n1\n0\n0\n"
run_tui_sequence "TUI Robot: run oak camera" "4\n2\n0\n0\n"
run_tui_sequence "TUI Robot: run rtabmap rgbd" "4\n3\n0\n0\n"
run_tui_sequence "TUI Robot: record raw bag" "4\n4\n0\n0\n"
run_tui_sequence "TUI Robot: run nav2" "4\n5\n0\n0\n"
run_tui_sequence "TUI Robot: send nav2 goal" "4\n6\n0\n0\n"
run_tui_sequence "TUI Robot: teleop keyboard" "4\n7\n0\n0\n"
run_tui_sequence "TUI Robot: teleop arrows" "4\n8\n0\n0\n"
run_tui_sequence "TUI Robot: ros health" "4\n9\n0\n0\n"

# Diagnostics menu actions (safe mode)
run_tui_sequence "TUI Diagnostics: docker status" "5\n2\n0\n0\n"
run_tui_sequence "TUI Diagnostics: viewer containers" "5\n3\n0\n0\n"
run_tui_sequence "TUI Diagnostics: cleanup stale state" "5\n4\n0\n0\n"

echo ""
echo "Self-test summary: ${passes} passed, ${failures} failed."
if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "All tested TUI actions passed."
