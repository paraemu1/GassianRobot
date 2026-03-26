#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RUN_DIR=""
DB_PATH=""
OUTPUT_DIR=""
FRAME_STRIDE="${RTABMAP_FRAME_STRIDE:-1}"
POINT_STRIDE="${RTABMAP_POINT_STRIDE:-24}"
MAX_DEPTH_M="${RTABMAP_MAX_DEPTH_M:-4.5}"
FORCE=0
RUNTIME_IMAGE="${ROS_IMAGE:-gassian/robot-runtime:latest}"

usage() {
  cat <<'USAGE'
Export an RTAB-Map database run to a Nerfstudio-style dataset.

Usage:
  ./scripts/gaussian/export_rtabmap_run_to_nerfstudio.sh --run <runs/...> [options]
  ./scripts/gaussian/export_rtabmap_run_to_nerfstudio.sh --db <path/to/rtabmap.db> --output-dir <dataset-dir> [options]

Options:
  --run <path>            Run directory containing rtabmap.db.
  --db <path>             RTAB-Map database path.
  --output-dir <path>     Dataset output dir. Default with --run: <run>/dataset
  --frame-stride <N>      Keep every Nth RTAB-Map node as a frame (default: 1)
  --point-stride <N>      Depth sampling stride for sparse seed cloud (default: 24)
  --max-depth-m <M>       Max depth used for the sparse seed cloud (default: 4.5)
  --force                 Replace the existing output dataset dir.
  -h, --help              Show this help.

Environment:
  ROS_IMAGE               Runtime image used to build/run the helper
                          (default: gassian/robot-runtime:latest)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --db)
      DB_PATH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --frame-stride)
      FRAME_STRIDE="$2"
      shift 2
      ;;
    --point-stride)
      POINT_STRIDE="$2"
      shift 2
      ;;
    --max-depth-m)
      MAX_DEPTH_M="$2"
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

if [[ -n "$RUN_DIR" ]]; then
  RUN_DIR="$(realpath -m "$RUN_DIR")"
  if [[ -z "$DB_PATH" ]]; then
    DB_PATH="${RUN_DIR}/rtabmap.db"
  fi
  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="${RUN_DIR}/dataset"
  fi
fi

if [[ -z "$DB_PATH" ]]; then
  echo "Either --run or --db is required." >&2
  exit 1
fi

DB_PATH="$(realpath -m "$DB_PATH")"
if [[ ! -f "$DB_PATH" ]]; then
  echo "RTAB-Map database not found: $DB_PATH" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "--output-dir is required when --run is not used." >&2
  exit 1
fi
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

for value in "$DB_PATH" "$OUTPUT_DIR"; do
  if [[ "$value" != "${REPO_ROOT}"/* ]]; then
    echo "Path must stay inside the repo for Docker mode: $value" >&2
    exit 1
  fi
done

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker and retry." >&2
  exit 1
fi

HELPER_SRC="${REPO_ROOT}/tools/rtabmap_db_to_nerfstudio.cc"
HELPER_BIN="${REPO_ROOT}/.tmp/rtabmap_dataset_helper/rtabmap_db_to_nerfstudio"
mkdir -p "$(dirname "$HELPER_BIN")"

rel_db="${DB_PATH#${REPO_ROOT}/}"
rel_out="${OUTPUT_DIR#${REPO_ROOT}/}"
rel_helper_bin="${HELPER_BIN#${REPO_ROOT}/}"
rel_helper_src="${HELPER_SRC#${REPO_ROOT}/}"

compile_helper() {
  docker run --rm \
    -v "${REPO_ROOT}:/workspace" \
    -w /workspace \
    "$RUNTIME_IMAGE" \
    bash -lc "
      set -euo pipefail
      g++ -std=c++17 -O2 -Wall -Wextra \
        -I/opt/ros/humble/include \
        -I/opt/ros/humble/include/rtabmap-0.22 \
        -I/usr/include/pcl-1.12 \
        -I/usr/include/eigen3 \
        \$(pkg-config --cflags opencv4) \
        /workspace/${rel_helper_src} \
        -o /workspace/${rel_helper_bin} \
        -L/opt/ros/humble/lib/aarch64-linux-gnu \
        -Wl,-rpath,/opt/ros/humble/lib/aarch64-linux-gnu \
        -lrtabmap_core \
        -lsqlite3 \
        \$(pkg-config --libs opencv4)
    "
}

if [[ ! -x "$HELPER_BIN" || "$HELPER_SRC" -nt "$HELPER_BIN" ]]; then
  echo "Compiling RTAB-Map dataset helper..."
  compile_helper
fi

helper_args=(
  "/workspace/${rel_helper_bin}"
  --db "/workspace/${rel_db}"
  --output-dir "/workspace/${rel_out}"
  --frame-stride "$FRAME_STRIDE"
  --point-stride "$POINT_STRIDE"
  --max-depth-m "$MAX_DEPTH_M"
)
if [[ "$FORCE" -eq 1 ]]; then
  helper_args+=(--overwrite)
fi

echo "Exporting RTAB-Map run to Nerfstudio dataset..."
docker run --rm \
  -v "${REPO_ROOT}:/workspace" \
  -w /workspace \
  "$RUNTIME_IMAGE" \
  "${helper_args[@]}"

echo "Dataset ready: ${OUTPUT_DIR}"
