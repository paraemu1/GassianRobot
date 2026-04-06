#!/usr/bin/env bash
set -euo pipefail

# Minimal Jetson-friendly processing pipeline:
# ns-process-data video -> ns-train splatfacto -> ns-export gaussian-splat
#
# Example:
# ./scripts/gaussian/process_train_export.sh \
#   --video runs/2026-02-17-lab/raw/capture.mp4 \
#   --run runs/2026-02-17-lab \
#   --downscale 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIDEO_PATH=""
RUN_DIR=""
DOWNSCALE=1
PROCESS_GPU="${PROCESS_GPU:-0}" # 1 to enable GPU SIFT in COLMAP
USE_DOCKER=1
MODE="video"
DATASET_DIR=""
TRAIN_IMAGE="${TRAIN_IMAGE:-gassian/gsplat-train:jetson-compatible}"
TRAIN_EXTRA_ARGS="${TRAIN_EXTRA_ARGS:-}"
PREAMBLE_CMD="python3 -m pip uninstall -y opencv-python opencv-python-headless >/dev/null 2>&1 || true; rm -rf /usr/local/lib/python3.8/dist-packages/cv2 /usr/local/lib/python3.8/dist-packages/cv2.*; python3 -m pip install --no-cache-dir opencv-python-headless==4.8.1.78 >/dev/null"
DATASET_IS_RTABMAP=0

usage() {
  echo "Usage:"
  echo "  $0 --video <video.mp4> --run <runs/YYYY-MM-DD-scene> [--downscale N] [--host]"
  echo "  $0 --run <runs/YYYY-MM-DD-scene> --from-run-env [--downscale N] [--host]"
  echo "  $0 --dataset <prepared_dataset_dir> --run <runs/YYYY-MM-DD-scene> [--host]"
  echo ""
  echo "Flags:"
  echo "  --host          run ns-* commands on host instead of Docker"
  echo "  --from-run-env  read VIDEO_PATH or DATASET_DIR from <run>/gs_input.env"
}

ensure_dataset_downscale_pyramid() {
  local dataset_dir="$1"
  local downscale="$2"

  if [[ "$downscale" -le 1 ]]; then
    return 0
  fi

  python3 "${SCRIPT_DIR}/ensure_dataset_downscale_pyramid.py" \
    --dataset "$dataset_dir" \
    --downscale "$downscale"
}

ensure_dataset_downscale_pyramid_docker() {
  local dataset_dir="$1"
  local downscale="$2"
  local abs_dataset rel_dataset

  if [[ "$downscale" -le 1 ]]; then
    return 0
  fi

  abs_dataset="$(realpath "$dataset_dir")"
  if [[ "$abs_dataset" != "${PWD}"/* ]]; then
    echo "Dataset path must be inside repo for docker downscale prep: $dataset_dir"
    exit 1
  fi
  rel_dataset="${abs_dataset#${PWD}/}"

  docker run --rm --network host --ipc host --runtime nvidia \
    -v "${PWD}:/workspace" -w /workspace \
    "$TRAIN_IMAGE" \
    python3 scripts/gaussian/ensure_dataset_downscale_pyramid.py \
      --dataset "/workspace/${rel_dataset}" \
      --downscale "$downscale"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --video)
      VIDEO_PATH="$2"
      shift 2
      ;;
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --downscale)
      DOWNSCALE="$2"
      shift 2
      ;;
    --dataset)
      MODE="dataset"
      DATASET_DIR="$2"
      shift 2
      ;;
    --from-run-env)
      MODE="run_env"
      shift 1
      ;;
    --host)
      USE_DOCKER=0
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$RUN_DIR" ]]; then
  usage
  exit 1
fi

RUN_DIR="$(realpath -m "$RUN_DIR")"

if [[ "$MODE" == "run_env" ]]; then
  env_file="${RUN_DIR}/gs_input.env"
  if [[ ! -f "$env_file" ]]; then
    echo "Missing $env_file"
    echo "Run: ./scripts/gaussian/prepare_gs_input_from_run.sh --run $RUN_DIR"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$env_file"
  if [[ -n "${DATASET_DIR:-}" ]]; then
    MODE="dataset"
  else
    MODE="video"
  fi
fi

if [[ "$MODE" == "video" ]]; then
  if [[ -z "$VIDEO_PATH" || ! -f "$VIDEO_PATH" ]]; then
    echo "Video not found: $VIDEO_PATH"
    exit 1
  fi
fi

if [[ "$MODE" == "dataset" ]]; then
  if [[ -z "$DATASET_DIR" || ! -d "$DATASET_DIR" ]]; then
    echo "Dataset dir not found: $DATASET_DIR"
    exit 1
  fi
  if [[ -f "${DATASET_DIR}/.rtabmap_nerfstudio_export" || "${GS_INPUT_SOURCE:-}" == "rtabmap-db" ]]; then
    DATASET_IS_RTABMAP=1
  fi
fi

mkdir -p "${RUN_DIR}/dataset" "${RUN_DIR}/checkpoints" "${RUN_DIR}/exports" "${RUN_DIR}/logs"

if [[ "$DATASET_IS_RTABMAP" -eq 1 ]] && [[ "${TRAIN_EXTRA_ARGS}" != *"--pipeline.model.random-init"* ]]; then
  TRAIN_EXTRA_ARGS="${TRAIN_EXTRA_ARGS} --pipeline.model.random-init True"
  echo "Detected RTAB-Map Nerfstudio dataset; enabling splatfacto random initialization."
fi

process_gpu_flag="--no-gpu"
if [[ "$PROCESS_GPU" == "1" || "$PROCESS_GPU" == "true" || "$PROCESS_GPU" == "True" ]]; then
  process_gpu_flag="--gpu"
fi

run_host() {
  for cmd in ns-process-data ns-train ns-export; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required host command: $cmd"
      exit 1
    fi
  done

  if [[ "$MODE" == "video" ]]; then
    echo "[1/3] Processing video -> dataset (host)"
    ns-process-data video \
      --data "$VIDEO_PATH" \
      --output-dir "${RUN_DIR}/dataset" \
      --num-downscales "$DOWNSCALE" \
      "$process_gpu_flag" \
      2>&1 | tee "${RUN_DIR}/logs/ns-process-data.log"
  else
    echo "[1/3] Skipping process stage; using dataset: $DATASET_DIR"
    local dataset_abs target_abs
    dataset_abs="$(realpath "$DATASET_DIR")"
    target_abs="$(realpath -m "${RUN_DIR}/dataset")"
    if [[ "$dataset_abs" == "$target_abs" ]]; then
      echo "Dataset source matches ${RUN_DIR}/dataset; leaving existing dataset in place."
    else
      rm -rf "${RUN_DIR}/dataset"
      mkdir -p "${RUN_DIR}/dataset"
      cp -a "${DATASET_DIR}/." "${RUN_DIR}/dataset/"
    fi
  fi

  if [[ "$MODE" == "dataset" ]]; then
    ensure_dataset_downscale_pyramid "${RUN_DIR}/dataset" "$DOWNSCALE" \
      2>&1 | tee -a "${RUN_DIR}/logs/ns-process-data.log"
  fi

  echo "[2/3] Training splatfacto (host)"
  # shellcheck disable=SC2086
  ns-train splatfacto \
    --data "${RUN_DIR}/dataset" \
    --output-dir "${RUN_DIR}/checkpoints" \
    $TRAIN_EXTRA_ARGS \
    2>&1 | tee "${RUN_DIR}/logs/ns-train.log"
}

run_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: docker"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry."
    exit 1
  fi

  local abs_run abs_video abs_dataset rel_run rel_video rel_dataset process_cmd train_cmd
  abs_run="$(realpath "$RUN_DIR")"
  abs_video="${VIDEO_PATH}"
  abs_dataset="${DATASET_DIR}"
  if [[ -n "$abs_video" ]]; then abs_video="$(realpath "$VIDEO_PATH")"; fi
  if [[ -n "$abs_dataset" ]]; then abs_dataset="$(realpath "$DATASET_DIR")"; fi

  if [[ "$abs_run" != "${PWD}"/* ]]; then
    echo "--run must be inside repo for docker mode: $RUN_DIR"
    exit 1
  fi
  rel_run="${abs_run#${PWD}/}"

  if [[ -n "$abs_video" ]]; then
    if [[ "$abs_video" != "${PWD}"/* ]]; then
      echo "--video must be inside repo for docker mode: $VIDEO_PATH"
      exit 1
    fi
    rel_video="${abs_video#${PWD}/}"
  fi

  if [[ -n "$abs_dataset" ]]; then
    if [[ "$abs_dataset" != "${PWD}"/* ]]; then
      echo "--dataset must be inside repo for docker mode: $DATASET_DIR"
      exit 1
    fi
    rel_dataset="${abs_dataset#${PWD}/}"
  fi

  if [[ "$MODE" == "video" ]]; then
    process_cmd="${PREAMBLE_CMD} && ns-process-data video --data /workspace/${rel_video} --output-dir /workspace/${rel_run}/dataset --num-downscales ${DOWNSCALE} ${process_gpu_flag}"
  else
    local run_dataset_abs
    run_dataset_abs="${abs_run}/dataset"
    if [[ "$abs_dataset" == "$run_dataset_abs" ]]; then
      process_cmd="echo 'Dataset source matches target; leaving /workspace/${rel_run}/dataset in place.' && mkdir -p /workspace/${rel_run}/dataset"
    else
      process_cmd="rm -rf /workspace/${rel_run}/dataset && mkdir -p /workspace/${rel_run}/dataset && cp -a /workspace/${rel_dataset}/. /workspace/${rel_run}/dataset/"
    fi
  fi
  train_cmd="${PREAMBLE_CMD} && ns-train splatfacto --data /workspace/${rel_run}/dataset --output-dir /workspace/${rel_run}/checkpoints ${TRAIN_EXTRA_ARGS}"

  if [[ "$MODE" == "video" ]]; then
    echo "[1/3] Processing video -> dataset (docker)"
    docker run --rm --network host --ipc host --runtime nvidia \
      -v "${PWD}:/workspace" -w /workspace \
      "$TRAIN_IMAGE" bash -lc "$process_cmd" \
      2>&1 | tee "${RUN_DIR}/logs/ns-process-data.log"
  else
    echo "[1/3] Skipping process stage; using dataset: $DATASET_DIR"
    docker run --rm --network host --ipc host --runtime nvidia \
      -v "${PWD}:/workspace" -w /workspace \
      "$TRAIN_IMAGE" bash -lc "$process_cmd" \
      2>&1 | tee "${RUN_DIR}/logs/ns-process-data.log"
  fi

  if [[ "$MODE" == "dataset" ]]; then
    ensure_dataset_downscale_pyramid_docker "${RUN_DIR}/dataset" "$DOWNSCALE" \
      2>&1 | tee -a "${RUN_DIR}/logs/ns-process-data.log"
  fi

  echo "[2/3] Training splatfacto (docker)"
  docker run --rm --network host --ipc host --runtime nvidia \
    -v "${PWD}:/workspace" -w /workspace \
    "$TRAIN_IMAGE" bash -lc "$train_cmd" \
    2>&1 | tee "${RUN_DIR}/logs/ns-train.log"
}

if [[ "$USE_DOCKER" -eq 1 ]]; then
  run_docker
else
  run_host
fi

latest_config="$(find "${RUN_DIR}/checkpoints" -name config.yml | sort | tail -n1 || true)"
if [[ -z "$latest_config" ]]; then
  echo "Could not find config.yml under ${RUN_DIR}/checkpoints"
  exit 1
fi

if [[ "$USE_DOCKER" -eq 1 ]]; then
  if [[ "$latest_config" != "${PWD}"/* ]]; then
    echo "Config path must be inside repo for docker mode: $latest_config"
    exit 1
  fi
  rel_config="${latest_config#${PWD}/}"
  rel_run="${RUN_DIR#${PWD}/}"
  echo "[3/3] Export gaussian splat (docker)"
  docker run --rm --network host --ipc host --runtime nvidia \
    -v "${PWD}:/workspace" -w /workspace \
    "$TRAIN_IMAGE" \
    bash -lc "${PREAMBLE_CMD}; ns-export gaussian-splat --load-config /workspace/${rel_config} --output-dir /workspace/${rel_run}/exports/splat" \
    2>&1 | tee "${RUN_DIR}/logs/ns-export.log"
else
  echo "[3/3] Export gaussian splat (host)"
  ns-export gaussian-splat \
    --load-config "$latest_config" \
    --output-dir "${RUN_DIR}/exports/splat" \
    2>&1 | tee "${RUN_DIR}/logs/ns-export.log"
fi

echo "Done. Export dir: ${RUN_DIR}/exports/splat"
