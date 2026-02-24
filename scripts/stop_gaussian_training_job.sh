#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
FORCE=0

usage() {
  cat <<'EOF'
Stop a background Gaussian training job started by start_gaussian_training_job.sh.

Usage:
  ./scripts/stop_gaussian_training_job.sh [--run <runs/YYYY-MM-DD-scene>|latest] [--force]

Options:
  --run <path|latest>
                Run directory. Default: latest.
  --force       Send SIGKILL if the process does not stop after SIGTERM.
  -h, --help    Show this help.
EOF
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

pid_file="${RUN_DIR}/logs/train_job.pid"

if [[ ! -f "$pid_file" ]]; then
  echo "PID file not found: $pid_file" >&2
  exit 1
fi

pid="$(cat "$pid_file" 2>/dev/null || true)"
if [[ -z "$pid" ]]; then
  echo "PID file is empty: $pid_file" >&2
  exit 1
fi

if ! ps -p "$pid" >/dev/null 2>&1; then
  echo "Process $pid is not running. Removing stale PID file."
  rm -f "$pid_file"
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
echo "Stopped."
