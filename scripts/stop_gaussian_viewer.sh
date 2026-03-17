#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
CONTAINER_NAME=""
DRY_RUN=0

usage() {
  cat <<'USAGE'
Stop a viewer container started by start_gaussian_viewer.sh.

Usage:
  ./scripts/stop_gaussian_viewer.sh [--run <runs/YYYY-MM-DD-scene>|latest | --container-name <name>]

Options:
  --run <path|latest>      Run directory used to derive the default container name.
                           Default: latest viewer-ready run.
  --container-name <name>  Explicit viewer container name.
  --dry-run                Resolve container name and print stop command.
  -h, --help               Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --container-name)
      CONTAINER_NAME="$2"
      shift 2
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

if [[ -z "$CONTAINER_NAME" ]]; then
  if ! RUN_DIR="$(run_utils_resolve_run_dir_for_context "$REPO_ROOT" "$RUN_DIR" "viewer_ready")"; then
    run_utils_list_runs "$REPO_ROOT" >&2
    exit 1
  fi
  run_base="$(basename "$RUN_DIR" | tr -cs 'a-zA-Z0-9' '_')"
  CONTAINER_NAME="gs_viewer_${run_base}"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: stop_gaussian_viewer.sh"
  echo "Container: $CONTAINER_NAME"
  echo "Would execute: docker rm -f $CONTAINER_NAME"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
echo "Stopped viewer container: $CONTAINER_NAME"
