#!/usr/bin/env bash
set -euo pipefail

# Prepare a Gaussian training input pointer from an RTAB-Map run folder.
# This does not discard RTAB-Map artifacts; it standardizes where training reads data.
#
# Usage:
# ./scripts/prepare_gs_input_from_run.sh --run runs/2026-02-17-lab_loop_a

RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 --run <runs/YYYY-MM-DD-scene>"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$RUN_DIR" ]]; then
  echo "Usage: $0 --run <runs/YYYY-MM-DD-scene>"
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run folder not found: $RUN_DIR"
  exit 1
fi

mkdir -p "$RUN_DIR/raw" "$RUN_DIR/logs"

# Prefer a direct capture.mp4 path, else choose the newest mp4 in raw/.
video_path=""
if [[ -f "$RUN_DIR/raw/capture.mp4" ]]; then
  video_path="$RUN_DIR/raw/capture.mp4"
else
  video_path="$(find "$RUN_DIR/raw" -maxdepth 1 -type f -name '*.mp4' | sort | tail -n1 || true)"
fi

if [[ -z "$video_path" ]]; then
  echo "No mp4 found in $RUN_DIR/raw."
  echo "Record a short RGB capture to $RUN_DIR/raw/capture.mp4, then retry."
  exit 1
fi

printf "VIDEO_PATH=%s\n" "$video_path" > "$RUN_DIR/gs_input.env"
printf "RUN_DIR=%s\n" "$RUN_DIR" >> "$RUN_DIR/gs_input.env"
printf "Prepared %s\n" "$RUN_DIR/gs_input.env"
