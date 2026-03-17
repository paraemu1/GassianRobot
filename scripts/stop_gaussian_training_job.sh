#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
FORCE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Stop a background Gaussian training job started by start_gaussian_training_job.sh.

Usage:
  ./scripts/stop_gaussian_training_job.sh [--run <runs/YYYY-MM-DD-scene>|latest] [--force]

Options:
  --run <path|latest>
                Run directory. Default: latest run with training metadata.
  --force       Send SIGKILL if the process does not stop after SIGTERM.
  --dry-run     Resolve target and print what would be stopped.
  -h, --help    Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift 1
      ;;
    --dry-run)
      DRY_RUN=1
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

if ! RUN_DIR="$(run_utils_resolve_run_dir_for_context "$REPO_ROOT" "$RUN_DIR" "train_metadata")"; then
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

status_env="$(${SCRIPT_DIR}/training_job_status.sh --run "$RUN_DIR" --format env)"

state=""
pid=""
active_pid=0
pid_file="${RUN_DIR}/logs/train_job.pid"
status_file="${RUN_DIR}/logs/train_job.status"

while IFS='=' read -r key value; do
  case "$key" in
    STATE) state="$value" ;;
    PID) pid="$value" ;;
    ACTIVE_PID) active_pid="$value" ;;
    PID_FILE) pid_file="$value" ;;
    STATUS_FILE) status_file="$value" ;;
  esac
done <<< "$status_env"

write_exited_status() {
  local exit_code="$1"
  local started_at mode log_file launcher
  started_at="$(run_utils_read_status_value "$status_file" "started_at" || true)"
  mode="$(run_utils_read_status_value "$status_file" "mode" || true)"
  log_file="$(run_utils_read_status_value "$status_file" "log_file" || true)"
  launcher="$(run_utils_read_status_value "$status_file" "launcher" || true)"

  if [[ -z "$started_at" ]]; then
    started_at="$(date -Is)"
  fi

  cat > "$status_file" <<STATUS
state=exited
run_dir=${RUN_DIR}
pid=${pid}
started_at=${started_at}
ended_at=$(date -Is)
exit_code=${exit_code}
mode=${mode}
log_file=${log_file}
launcher=${launcher}
STATUS
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: stop_gaussian_training_job.sh"
  echo "Run: $RUN_DIR"
  echo "State: $state"
  echo "PID: ${pid:-<none>}"
  echo "Active PID: $active_pid"
  echo "PID file: $pid_file"
  echo "Status file: $status_file"
  exit 0
fi

if [[ -z "$pid" ]]; then
  echo "No PID recorded for run: $RUN_DIR"
  if [[ "$state" == "running" && -f "$status_file" ]]; then
    write_exited_status 143
    echo "Updated stale running status to exited (143)."
  fi
  exit 0
fi

if [[ "$active_pid" -ne 1 ]]; then
  echo "Process $pid is not running."
  rm -f "$pid_file"
  if [[ "$state" == "running" && -f "$status_file" ]]; then
    write_exited_status 143
    echo "Updated stale running status to exited (143)."
  fi
  exit 0
fi

echo "Stopping PID $pid..."
pkill -TERM -P "$pid" >/dev/null 2>&1 || true
kill -TERM "$pid" >/dev/null 2>&1 || true
sleep 2

if ps -p "$pid" >/dev/null 2>&1; then
  if [[ "$FORCE" -eq 1 ]]; then
    echo "Process still running. Sending SIGKILL."
    pkill -KILL -P "$pid" >/dev/null 2>&1 || true
    kill -KILL "$pid" >/dev/null 2>&1 || true
    sleep 1
  else
    echo "Process is still running. Re-run with --force if needed." >&2
    exit 1
  fi
fi

if ps -p "$pid" >/dev/null 2>&1; then
  echo "Failed to stop process $pid." >&2
  exit 1
fi

rm -f "$pid_file"
if [[ -f "$status_file" ]]; then
  write_exited_status 143
fi

echo "Stopped."
