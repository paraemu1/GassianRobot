#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RUN_DIR=""
SOURCE_MODE="auto" # auto | dataset | rtabmap-db | video
FORCE=0

usage() {
  cat <<'USAGE'
Prepare Gaussian training input metadata from an existing run.

Usage:
  ./scripts/gaussian/prepare_gs_input_from_run.sh --run <runs/YYYY-MM-DD-scene> [options]

Options:
  --run <path>                  Run directory to prepare.
  --source <auto|dataset|rtabmap-db|video>
                                Input source selection. Default: auto.
  --force                       Re-export RTAB-Map dataset even if dataset/transforms.json exists.
  -h, --help                    Show this help.

Auto-detection preference:
  1. Existing dataset/transforms.json
  2. rtabmap.db
  3. raw/capture.mp4 or newest raw/*.mp4
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --source)
      SOURCE_MODE="$2"
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

if [[ -z "$RUN_DIR" ]]; then
  usage
  exit 1
fi

if [[ "$SOURCE_MODE" != "auto" && "$SOURCE_MODE" != "dataset" && "$SOURCE_MODE" != "rtabmap-db" && "$SOURCE_MODE" != "video" ]]; then
  echo "Invalid --source: $SOURCE_MODE" >&2
  exit 1
fi

RUN_DIR="$(realpath -m "$RUN_DIR")"
if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run folder not found: $RUN_DIR" >&2
  exit 1
fi

mkdir -p "$RUN_DIR/raw" "$RUN_DIR/logs" "$RUN_DIR/dataset"

DATASET_DIR="${RUN_DIR}/dataset"
DATASET_TRANSFORMS="${DATASET_DIR}/transforms.json"
RTABMAP_DB_PATH="${RUN_DIR}/rtabmap.db"

video_path=""
if [[ -f "$RUN_DIR/raw/capture.mp4" ]]; then
  video_path="$RUN_DIR/raw/capture.mp4"
else
  video_path="$(find "$RUN_DIR/raw" -maxdepth 1 -type f -name '*.mp4' | sort | tail -n1 || true)"
fi

resolved_source="$SOURCE_MODE"
if [[ "$SOURCE_MODE" == "auto" ]]; then
  if [[ -f "$DATASET_TRANSFORMS" ]]; then
    resolved_source="dataset"
  elif [[ -f "$RTABMAP_DB_PATH" ]]; then
    resolved_source="rtabmap-db"
  elif [[ -n "$video_path" ]]; then
    resolved_source="video"
  else
    echo "No supported Gaussian input source found in $RUN_DIR." >&2
    echo "Expected one of:" >&2
    echo "  - dataset/transforms.json" >&2
    echo "  - rtabmap.db" >&2
    echo "  - raw/capture.mp4 or another raw/*.mp4" >&2
    exit 1
  fi
fi

if [[ "$resolved_source" == "dataset" ]]; then
  if [[ ! -f "$DATASET_TRANSFORMS" ]]; then
    echo "Dataset source requested, but missing: $DATASET_TRANSFORMS" >&2
    exit 1
  fi
elif [[ "$resolved_source" == "rtabmap-db" ]]; then
  if [[ ! -f "$RTABMAP_DB_PATH" ]]; then
    echo "RTAB-Map source requested, but missing: $RTABMAP_DB_PATH" >&2
    exit 1
  fi
  if [[ "$FORCE" -eq 1 || ! -f "$DATASET_TRANSFORMS" ]]; then
    "${SCRIPT_DIR}/export_rtabmap_run_to_nerfstudio.sh" \
      --run "$RUN_DIR" \
      --force
  fi
  if [[ ! -f "$DATASET_TRANSFORMS" ]]; then
    echo "RTAB-Map export did not produce: $DATASET_TRANSFORMS" >&2
    exit 1
  fi
elif [[ "$resolved_source" == "video" ]]; then
  if [[ -z "$video_path" || ! -f "$video_path" ]]; then
    echo "Video source requested, but no mp4 found in $RUN_DIR/raw." >&2
    exit 1
  fi
fi

{
  printf "RUN_DIR=%s\n" "$RUN_DIR"
  printf "GS_INPUT_SOURCE=%s\n" "$resolved_source"
  if [[ "$resolved_source" == "video" ]]; then
    printf "VIDEO_PATH=%s\n" "$video_path"
  else
    printf "DATASET_DIR=%s\n" "$DATASET_DIR"
  fi
} > "$RUN_DIR/gs_input.env"

echo "Prepared $RUN_DIR/gs_input.env"
echo "Source: $resolved_source"
if [[ "$resolved_source" == "video" ]]; then
  echo "Video: $video_path"
else
  echo "Dataset: $DATASET_DIR"
fi
