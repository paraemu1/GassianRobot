#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/_run_utils.sh"

RUN_DIR=""
FORCE=0
ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Soft-delete a run by moving it into runs/.trash.

Usage:
  ./scripts/run_tools/delete_run.sh [--run <runs/...>|latest] [--force] [--yes]

Options:
  --run <path|latest>      Run directory to delete. Default: latest run.
  --force                  Allow delete even when training/viewer appears active.
  --yes                    Skip interactive confirmation prompt.
  --dry-run                Print what would happen.
  -h, --help               Show this help.
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
    --yes)
      ASSUME_YES=1
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

if ! RUN_DIR="$(run_utils_resolve_run_dir "$REPO_ROOT" "$RUN_DIR")"; then
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run directory not found: $RUN_DIR" >&2
  exit 1
fi

runs_root="${REPO_ROOT}/runs"
trash_root="${runs_root}/.trash"

if [[ "$RUN_DIR" != "${runs_root}/"* ]]; then
  echo "Refusing delete outside ${runs_root}: $RUN_DIR" >&2
  exit 1
fi

run_base="$(basename "$RUN_DIR")"
if [[ "$run_base" == "_template" ]]; then
  echo "Refusing to delete reserved run: $run_base" >&2
  exit 1
fi

if [[ "$RUN_DIR" == "${trash_root}"/* ]]; then
  echo "Run is already in trash: $RUN_DIR" >&2
  exit 1
fi

active_train=0
pid_file="${RUN_DIR}/logs/train_job.pid"
if [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
    active_train=1
  fi
fi

viewer_container="gs_viewer_$(basename "$RUN_DIR" | tr -cs 'a-zA-Z0-9' '_')"
active_viewer=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -Fxq "$viewer_container"; then
    active_viewer=1
  fi
fi

if [[ "$FORCE" -ne 1 ]]; then
  if [[ "$active_train" -eq 1 ]]; then
    echo "Refusing to delete; training process is active for this run." >&2
    echo "Stop it first: ./scripts/gaussian/stop_gaussian_training_job.sh --run $RUN_DIR" >&2
    exit 1
  fi
  if [[ "$active_viewer" -eq 1 ]]; then
    echo "Refusing to delete; viewer container is active: $viewer_container" >&2
    echo "Stop it first: ./scripts/gaussian/stop_gaussian_viewer.sh --run $RUN_DIR" >&2
    exit 1
  fi
fi

delete_stamp="$(date +%F_%H%M%S)"
trash_entry="${delete_stamp}-${run_base}"
trash_dest="${trash_root}/${trash_entry}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: delete_run.sh"
  echo "Run: $RUN_DIR"
  echo "Trash destination: $trash_dest"
  echo "Active training: $active_train"
  echo "Active viewer: $active_viewer (${viewer_container})"
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo "About to move run to trash: ${RUN_DIR#${REPO_ROOT}/}"
  read -rp "Type DELETE to confirm: " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    echo "Cancelled."
    exit 1
  fi
fi

mkdir -p "$trash_root"
mv "$RUN_DIR" "$trash_dest"

cat > "${trash_dest}/.trash_meta.env" <<META
DELETED_AT=${delete_stamp}
ORIGINAL_BASENAME=${run_base}
ORIGINAL_REL=runs/${run_base}
VIEWER_CONTAINER=${viewer_container}
META

echo "Moved run to trash: ${trash_dest#${REPO_ROOT}/}"
