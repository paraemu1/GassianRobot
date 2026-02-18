#!/usr/bin/env bash
set -euo pipefail

# Minimal Jetson-friendly processing pipeline:
# ns-process-data video -> ns-train splatfacto -> ns-export gaussian-splat
#
# Example:
# ./scripts/process_train_export.sh \
#   --video runs/2026-02-17-lab/raw/capture.mp4 \
#   --run runs/2026-02-17-lab \
#   --downscale 2

VIDEO_PATH=""
RUN_DIR=""
DOWNSCALE=1
USE_DOCKER=1
MODE="video"
DATASET_DIR=""
TRAIN_IMAGE="${TRAIN_IMAGE:-gassian/gsplat-train:latest}"

usage() {
  echo "Usage:"
  echo "  $0 --video <video.mp4> --run <runs/YYYY-MM-DD-scene> [--downscale N] [--host]"
  echo "  $0 --run <runs/YYYY-MM-DD-scene> --from-run-env [--downscale N] [--host]"
  echo "  $0 --dataset <prepared_dataset_dir> --run <runs/YYYY-MM-DD-scene> [--host]"
  echo ""
  echo "Flags:"
  echo "  --host          run ns-* commands on host instead of Docker"
  echo "  --from-run-env  read VIDEO_PATH from <run>/gs_input.env"
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
    echo "Run: ./scripts/prepare_gs_input_from_run.sh --run $RUN_DIR"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$env_file"
fi

if [[ "$MODE" == "video" || "$MODE" == "run_env" ]]; then
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
fi

mkdir -p "${RUN_DIR}/dataset" "${RUN_DIR}/checkpoints" "${RUN_DIR}/exports" "${RUN_DIR}/logs"

run_host() {
  for cmd in ns-process-data ns-train ns-export; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required host command: $cmd"
      exit 1
    fi
  done

  if [[ "$MODE" == "video" || "$MODE" == "run_env" ]]; then
    echo "[1/3] Processing video -> dataset (host)"
    ns-process-data video \
      --data "$VIDEO_PATH" \
      --output-dir "${RUN_DIR}/dataset" \
      --downscale-factor "$DOWNSCALE" \
      2>&1 | tee "${RUN_DIR}/logs/ns-process-data.log"
  else
    echo "[1/3] Skipping process stage; using dataset: $DATASET_DIR"
    rm -rf "${RUN_DIR}/dataset"
    mkdir -p "${RUN_DIR}/dataset"
    cp -a "${DATASET_DIR}/." "${RUN_DIR}/dataset/"
  fi

  echo "[2/3] Training splatfacto (host)"
  ns-train splatfacto \
    --data "${RUN_DIR}/dataset" \
    --output-dir "${RUN_DIR}/checkpoints" \
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

  if [[ "$MODE" == "video" || "$MODE" == "run_env" ]]; then
    process_cmd="ns-process-data video --data /workspace/${rel_video} --output-dir /workspace/${rel_run}/dataset --downscale-factor ${DOWNSCALE}"
  else
    process_cmd="rm -rf /workspace/${rel_run}/dataset && mkdir -p /workspace/${rel_run}/dataset && cp -a /workspace/${rel_dataset}/. /workspace/${rel_run}/dataset/"
  fi
  train_cmd="ns-train splatfacto --data /workspace/${rel_run}/dataset --output-dir /workspace/${rel_run}/checkpoints"

  if [[ "$MODE" == "video" || "$MODE" == "run_env" ]]; then
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
    bash -lc "ns-export gaussian-splat --load-config /workspace/${rel_config} --output-dir /workspace/${rel_run}/exports/splat" \
    2>&1 | tee "${RUN_DIR}/logs/ns-export.log"
else
  echo "[3/3] Export gaussian splat (host)"
  ns-export gaussian-splat \
    --load-config "$latest_config" \
    --output-dir "${RUN_DIR}/exports/splat" \
    2>&1 | tee "${RUN_DIR}/logs/ns-export.log"
fi

echo "Done. Export dir: ${RUN_DIR}/exports/splat"
