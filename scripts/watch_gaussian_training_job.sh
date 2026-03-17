#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
LINES=80
FOLLOW=1
DRY_RUN=0

usage() {
  cat <<'USAGE'
Watch logs for a long-running Gaussian training job.

Usage:
  ./scripts/watch_gaussian_training_job.sh [--run <runs/YYYY-MM-DD-scene>|latest] [options]

Options:
  --run <path|latest>
                  Run directory. Default: latest run with training logs.
  --lines <N>     Number of log lines to show before following (default: 80).
  --no-follow     Print lines and exit.
  --dry-run       Validate log discovery and print the tail command.
  -h, --help      Show this help.
USAGE
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

if ! RUN_DIR="$(run_utils_resolve_run_dir_for_context "$REPO_ROOT" "$RUN_DIR" "train_logs")"; then
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

"${SCRIPT_DIR}/training_job_status.sh" --run "$RUN_DIR"

echo "Log: $log_file"
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$FOLLOW" -eq 1 ]]; then
    echo "Dry run: would execute: tail -n $LINES -f $log_file"
  else
    echo "Dry run: would execute: tail -n $LINES $log_file"
  fi
  exit 0
fi

if [[ "$FOLLOW" -eq 1 ]]; then
  tail -n "$LINES" -f "$log_file"
else
  tail -n "$LINES" "$log_file"
fi
