#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
LINES=80
FOLLOW=1

usage() {
  cat <<'EOF'
Watch logs for a long-running Gaussian training job.

Usage:
  ./scripts/watch_gaussian_training_job.sh [--run <runs/YYYY-MM-DD-scene>|latest] [options]

Options:
  --run <path|latest>
                  Run directory. Default: latest.
  --lines <N>     Number of log lines to show before following (default: 80).
  --no-follow     Print lines and exit.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --lines)
      LINES="$2"
      shift 2
      ;;
    --no-follow)
      FOLLOW=0
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

if ! RUN_DIR="$(run_utils_resolve_run_dir "$REPO_ROOT" "$RUN_DIR")"; then
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run directory not found: $RUN_DIR" >&2
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

latest_link="${RUN_DIR}/logs/train_job.latest.log"
if [[ -L "$latest_link" || -f "$latest_link" ]]; then
  log_file="$(realpath -m "$latest_link")"
else
  log_file="$(ls -1t "${RUN_DIR}"/logs/train_job_*.log 2>/dev/null | head -n1 || true)"
fi

if [[ -z "$log_file" || ! -f "$log_file" ]]; then
  echo "No training log found under ${RUN_DIR}/logs." >&2
  exit 1
fi

pid_file="${RUN_DIR}/logs/train_job.pid"
if [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
    echo "Training process is running (PID $pid)."
  else
    echo "No active process for PID in $pid_file."
  fi
else
  echo "No PID file found at $pid_file."
fi

echo "Log: $log_file"
if [[ "$FOLLOW" -eq 1 ]]; then
  tail -n "$LINES" -f "$log_file"
else
  tail -n "$LINES" "$log_file"
fi
