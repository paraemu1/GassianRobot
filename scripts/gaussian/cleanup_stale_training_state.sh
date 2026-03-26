#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/_run_utils.sh"

DRY_RUN=0

usage() {
  cat <<'USAGE'
Cleanup stale training pid/status artifacts across runs.

Usage:
  ./scripts/gaussian/cleanup_stale_training_state.sh [--dry-run]

Options:
  --dry-run    Show what would be changed.
  -h, --help   Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

updated=0

for run_dir in $(run_utils_all_runs "$REPO_ROOT"); do
  pid_file="${run_dir}/logs/train_job.pid"
  status_file="${run_dir}/logs/train_job.status"
  pid=""
  active=0

  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      active=1
    fi
  fi

  if [[ -f "$pid_file" && "$active" -eq 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "Would remove stale PID file: ${pid_file#${REPO_ROOT}/}"
    else
      rm -f "$pid_file"
      echo "Removed stale PID file: ${pid_file#${REPO_ROOT}/}"
    fi
    updated=$((updated + 1))
  fi

  if [[ -f "$status_file" ]]; then
    state="$(run_utils_read_status_value "$status_file" "state" || true)"
    if [[ "$state" == "running" && "$active" -eq 0 ]]; then
      started_at="$(run_utils_read_status_value "$status_file" "started_at" || true)"
      mode="$(run_utils_read_status_value "$status_file" "mode" || true)"
      log_file="$(run_utils_read_status_value "$status_file" "log_file" || true)"
      launcher="$(run_utils_read_status_value "$status_file" "launcher" || true)"
      if [[ -z "$started_at" ]]; then
        started_at="$(date -Is)"
      fi

      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Would mark stale running status exited: ${status_file#${REPO_ROOT}/}"
      else
        cat > "$status_file" <<STATUS
state=exited
run_dir=${run_dir}
pid=${pid}
started_at=${started_at}
ended_at=$(date -Is)
exit_code=143
mode=${mode}
log_file=${log_file}
launcher=${launcher}
STATUS
        echo "Marked stale running status exited: ${status_file#${REPO_ROOT}/}"
      fi
      updated=$((updated + 1))
    fi
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete. Items matched: $updated"
else
  echo "Cleanup complete. Items updated: $updated"
fi
