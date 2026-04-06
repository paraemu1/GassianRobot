#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/_run_utils.sh"

RUN_DIR=""
MODE="prep-train" # prep | train | prep-train
MAX_STEPS=30000
MAX_GAUSSIANS=1000000
SIDE_DOWNSCALE=""
SIDE_DOWNSCALE_SET=0
CUDA_MEMORY_FRACTION=0.8
TRAIN_IMAGE="${TRAIN_IMAGE:-gassian/gsplat-train:jetson-compatible}"
FORCE_PREPROCESS=0
DETACH=1
USE_HOST=0
DRY_RUN=0
JETSON_PREP_FRAME_STRIDE="${JETSON_PREP_FRAME_STRIDE:-3}"
JETSON_PREP_POINT_STRIDE="${JETSON_PREP_POINT_STRIDE:-16}"
JETSON_PREP_MAX_DEPTH_M="${JETSON_PREP_MAX_DEPTH_M:-4.5}"

usage() {
  cat <<'USAGE'
Start the Jetson-compatible low-memory Gaussian training path.

This launcher now delegates to the standard Nerfstudio/splatfacto training
pipeline that is already compatible with the pinned Jetson image. It keeps the
existing CLI surface for compatibility with the TUI and older commands.

Usage:
  ./scripts/gaussian/start_jetson_orin_nano_gsplat_training_job.sh [--run <runs/...>|latest] [options]

Options:
  --run <path|latest>      Run directory. Default: latest Jetson-gsplat-compatible run.
  --mode <prep|train|prep-train>
                           prep-train by default.
  --max-steps <N>          Training steps / max iterations (default: 30000).
  --max-gaussians <N>      Accepted for CLI compatibility but ignored by this compatible path.
  --side-downscale <N>     Override low-memory preprocessing downscale.
  --cuda-memory-fraction <f>
                           Accepted for CLI compatibility but ignored by this compatible path.
  --force-preprocess       Force re-preparation when prep is part of the mode.
  --train-image <tag>      Docker image tag (default: gassian/gsplat-train:jetson-compatible).
  --host                   Run on host instead of Docker.
  --foreground             Run attached in current terminal (default: detached).
  --dry-run                Print the translated launch plan without starting it.
  -h, --help               Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --max-steps)
      MAX_STEPS="$2"
      shift 2
      ;;
    --max-gaussians)
      MAX_GAUSSIANS="$2"
      shift 2
      ;;
    --side-downscale)
      SIDE_DOWNSCALE="$2"
      SIDE_DOWNSCALE_SET=1
      shift 2
      ;;
    --cuda-memory-fraction)
      CUDA_MEMORY_FRACTION="$2"
      shift 2
      ;;
    --force-preprocess)
      FORCE_PREPROCESS=1
      shift 1
      ;;
    --train-image)
      TRAIN_IMAGE="$2"
      shift 2
      ;;
    --host)
      USE_HOST=1
      shift 1
      ;;
    --foreground)
      DETACH=0
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

if [[ "$MODE" != "prep" && "$MODE" != "train" && "$MODE" != "prep-train" ]]; then
  echo "Invalid --mode: $MODE" >&2
  exit 1
fi

if ! RUN_DIR="$(run_utils_resolve_run_dir_for_context "$REPO_ROOT" "$RUN_DIR" "jetson_gsplat_trainable")"; then
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run directory not found: $RUN_DIR" >&2
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

dataparser_downscale="4"
if [[ "$SIDE_DOWNSCALE_SET" -eq 1 ]]; then
  dataparser_downscale="$SIDE_DOWNSCALE"
else
  dataparser_downscale="3"
fi

use_sparse_seed_init=0
if [[ -f "${RUN_DIR}/rtabmap.db" || -f "${RUN_DIR}/dataset/.rtabmap_nerfstudio_export" || -f "${RUN_DIR}/dataset/sparse_pc.ply" ]]; then
  use_sparse_seed_init=1
fi

jetson_extra_train_args="--steps-per-eval-batch 1000"
jetson_extra_train_args+=" --steps-per-eval-image 0"
jetson_extra_train_args+=" --steps-per-eval-all-images 0"
jetson_extra_train_args+=" --pipeline.datamanager.camera-res-scale-factor 0.75"
jetson_extra_train_args+=" --pipeline.datamanager.eval-num-images-to-sample-from 1"
jetson_extra_train_args+=" --pipeline.model.sh-degree 1"
jetson_extra_train_args+=" --pipeline.model.num-downscales 2"
jetson_extra_train_args+=" --pipeline.model.resolution-schedule 3000"
jetson_extra_train_args+=" --pipeline.model.ssim-lambda 0.1"
if [[ "$use_sparse_seed_init" -eq 1 ]]; then
  jetson_extra_train_args+=" --pipeline.model.random-init False"
else
  jetson_extra_train_args+=" --pipeline.model.random-init True"
  jetson_extra_train_args+=" --pipeline.model.num-random 4000"
fi
jetson_extra_train_args+=" nerfstudio-data --downscale-factor ${dataparser_downscale} --train-split-fraction 0.995 --load-3D-points $([[ "$use_sparse_seed_init" -eq 1 ]] && echo True || echo False)"

delegate_cmd=(
  "${SCRIPT_DIR}/start_gaussian_training_job.sh"
  --run "$RUN_DIR"
  --mode "$MODE"
  --memory-profile low
  --max-iters "$MAX_STEPS"
  --downscale "$dataparser_downscale"
  --train-image "$TRAIN_IMAGE"
  --extra-train-args "$jetson_extra_train_args"
)

if [[ "$USE_HOST" -eq 1 ]]; then
  delegate_cmd+=(--host)
fi
if [[ "$DETACH" -eq 0 ]]; then
  delegate_cmd+=(--foreground)
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  delegate_cmd+=(--dry-run)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: start_jetson_orin_nano_gsplat_training_job.sh"
  echo "Run: $RUN_DIR"
  echo "Mode: $MODE"
  echo "Delegates to low-memory splatfacto training for Jetson compatibility."
  echo "Backend: jetson-compatible-splatfacto"
  echo "Max steps: $MAX_STEPS"
  if [[ "$SIDE_DOWNSCALE_SET" -eq 1 ]]; then
    echo "Side downscale override: $SIDE_DOWNSCALE"
  else
    echo "Side downscale override: (using low-memory default from delegated trainer)"
  fi
  echo "Dataparser downscale factor: $dataparser_downscale"
  echo "RTAB-Map prep frame stride: $JETSON_PREP_FRAME_STRIDE"
  echo "RTAB-Map prep point stride: $JETSON_PREP_POINT_STRIDE"
  echo "RTAB-Map prep max depth (m): $JETSON_PREP_MAX_DEPTH_M"
  echo "Init mode: $([[ "$use_sparse_seed_init" -eq 1 ]] && echo sparse-seed || echo random-init)"
  echo "Train image: $TRAIN_IMAGE"
  echo "Launch mode: $([[ "$DETACH" -eq 1 ]] && echo detached || echo foreground)"
  echo "Executor: $([[ "$USE_HOST" -eq 1 ]] && echo host || echo docker)"
  echo "Delegated extra train args: $jetson_extra_train_args"
  if [[ "$MAX_GAUSSIANS" != "1000000" ]]; then
    echo "Note: --max-gaussians is ignored by this compatible path."
  fi
  if [[ "$CUDA_MEMORY_FRACTION" != "0.8" ]]; then
    echo "Note: --cuda-memory-fraction is ignored by this compatible path."
  fi
  if [[ "$FORCE_PREPROCESS" -eq 1 ]]; then
    echo "Note: force preprocess enabled."
  fi
fi

if [[ "$MAX_GAUSSIANS" != "1000000" && "$DRY_RUN" -ne 1 ]]; then
  echo "Note: --max-gaussians is ignored by the Jetson-compatible delegated path." >&2
fi
if [[ "$CUDA_MEMORY_FRACTION" != "0.8" && "$DRY_RUN" -ne 1 ]]; then
  echo "Note: --cuda-memory-fraction is ignored by the Jetson-compatible delegated path." >&2
fi

if [[ "$FORCE_PREPROCESS" -eq 1 ]]; then
  exec env \
    TRAINING_BACKEND="jetson-compatible-splatfacto" \
    GAUSSIAN_PREP_FORCE=1 \
    RTABMAP_FRAME_STRIDE="${JETSON_PREP_FRAME_STRIDE}" \
    RTABMAP_POINT_STRIDE="${JETSON_PREP_POINT_STRIDE}" \
    RTABMAP_MAX_DEPTH_M="${JETSON_PREP_MAX_DEPTH_M}" \
    "${delegate_cmd[@]}"
fi

exec env \
  TRAINING_BACKEND="jetson-compatible-splatfacto" \
  RTABMAP_FRAME_STRIDE="${JETSON_PREP_FRAME_STRIDE}" \
  RTABMAP_POINT_STRIDE="${JETSON_PREP_POINT_STRIDE}" \
  RTABMAP_MAX_DEPTH_M="${JETSON_PREP_MAX_DEPTH_M}" \
  "${delegate_cmd[@]}"
