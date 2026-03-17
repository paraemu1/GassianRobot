#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
FORMAT="human"

usage() {
  cat <<'USAGE'
Show Gaussian training job status for a run.

Usage:
  ./scripts/training_job_status.sh [--run <runs/...>|latest] [--format human|env]

Options:
  --run <path|latest>      Run directory. Default: latest run with job metadata/logs.
  --format <human|env>     Output format (default: human).
  -h, --help               Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
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

if [[ "$FORMAT" != "human" && "$FORMAT" != "env" ]]; then
  echo "Invalid --format: $FORMAT" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" || "$RUN_DIR" == "latest" ]]; then
  if ! RUN_DIR="$(run_utils_resolve_run_dir_for_context "$REPO_ROOT" "latest" "train_metadata")"; then
    run_utils_list_runs "$REPO_ROOT" >&2
    exit 1
  fi
else
  if ! RUN_DIR="$(run_utils_resolve_run_dir "$REPO_ROOT" "$RUN_DIR")"; then
    run_utils_list_runs "$REPO_ROOT" >&2
    exit 1
  fi
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run directory not found: $RUN_DIR" >&2
  exit 1
fi

run_rel="${RUN_DIR#${REPO_ROOT}/}"
pid_file="${RUN_DIR}/logs/train_job.pid"
status_file="${RUN_DIR}/logs/train_job.status"
latest_link="${RUN_DIR}/logs/train_job.latest.log"

log_file=""
if [[ -L "$latest_link" || -f "$latest_link" ]]; then
  log_file="$(realpath -m "$latest_link")"
else
  log_file="$(ls -1t "${RUN_DIR}"/logs/train_job_*.log 2>/dev/null | head -n1 || true)"
fi

pid=""
if [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file" 2>/dev/null || true)"
fi

active_pid=0
if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
  active_pid=1
fi

state=""
started_at=""
ended_at=""
exit_code=""
if [[ -f "$status_file" ]]; then
  state="$(run_utils_read_status_value "$status_file" "state" || true)"
  started_at="$(run_utils_read_status_value "$status_file" "started_at" || true)"
  ended_at="$(run_utils_read_status_value "$status_file" "ended_at" || true)"
  exit_code="$(run_utils_read_status_value "$status_file" "exit_code" || true)"
fi

has_logs=0
if run_utils_has_train_logs "$RUN_DIR"; then
  has_logs=1
fi

stale_pid=0
if [[ -n "$pid" && "$active_pid" -eq 0 ]]; then
  stale_pid=1
fi

if [[ "$active_pid" -eq 1 ]]; then
  effective_state="running"
elif [[ -n "$state" ]]; then
  effective_state="$state"
elif [[ "$has_logs" -eq 1 ]]; then
  effective_state="logs-only"
else
  effective_state="never-started"
fi

if [[ "$FORMAT" == "env" ]]; then
  echo "RUN_DIR=${RUN_DIR}"
  echo "RUN_REL=${run_rel}"
  echo "STATE=${effective_state}"
  echo "PID=${pid}"
  echo "ACTIVE_PID=${active_pid}"
  echo "STALE_PID=${stale_pid}"
  echo "STATUS_FILE=${status_file}"
  echo "PID_FILE=${pid_file}"
  echo "LOG_FILE=${log_file}"
  echo "EXIT_CODE=${exit_code}"
  echo "STARTED_AT=${started_at}"
  echo "ENDED_AT=${ended_at}"
  echo "HAS_LOGS=${has_logs}"
  exit 0
fi

echo "Run: ${run_rel}"
echo "State: ${effective_state}"
if [[ -n "$pid" ]]; then
  if [[ "$active_pid" -eq 1 ]]; then
    echo "PID: ${pid} (active)"
  else
    echo "PID: ${pid} (not running)"
  fi
else
  echo "PID: (none)"
fi

if [[ -n "$started_at" ]]; then
  echo "Started: ${started_at}"
fi
if [[ -n "$ended_at" ]]; then
  echo "Ended: ${ended_at}"
fi
if [[ -n "$exit_code" ]]; then
  echo "Exit code: ${exit_code}"
fi
if [[ -n "$log_file" ]]; then
  echo "Log: ${log_file}"
fi
if [[ "$stale_pid" -eq 1 ]]; then
  echo "Note: stale PID file detected at ${pid_file}"
fi
