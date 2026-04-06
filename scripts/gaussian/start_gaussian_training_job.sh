#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/_run_utils.sh"

RUN_DIR=""
MODE="prep-train" # prep | train | prep-train
DOWNSCALE=2
DOWNSCALE_SET=0
BLUR_THRESHOLD=4
MAX_ITERS=30000
VIS="tensorboard"
EXTRA_TRAIN_ARGS=""
TRAIN_IMAGE="${TRAIN_IMAGE:-gassian/gsplat-train:jetson-compatible}"
MEMORY_PROFILE=""
TRAINING_BACKEND="${TRAINING_BACKEND:-nerfstudio-splatfacto}"
DETACH=1
USE_HOST=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Start a long-running Gaussian training job for an existing run.

Usage:
  ./scripts/gaussian/start_gaussian_training_job.sh [--run <runs/YYYY-MM-DD-scene>|latest] [options]

Options:
  --run <path|latest>      Run directory. Default: latest trainable run.
  --mode <prep|train|prep-train>
                           prep-train by default.
  --memory-profile <low|medium|high>
                           Rebuild prep/training for a target memory level.
                           low = 8 GB RAM or less, medium = 16 GB RAM,
                           high = 32 GB RAM or more.
  --downscale <N>          ns-process-data downscale count (default: 2).
  --blur-threshold <f>     Blur filter threshold used in prep modes (default: 4).
  --max-iters <N>          Training iterations (default: 30000).
  --vis <viewer|tensorboard|wandb>
                           Nerfstudio visualization backend (default: tensorboard).
  --extra-train-args "<args>"
                           Extra args appended to ns-train.
  --train-image <tag>      Docker image tag (default: gassian/gsplat-train:jetson-compatible).
  --host                   Run on host instead of Docker.
  --foreground             Run attached in current terminal (default: detached).
  --dry-run                Validate inputs and print the command without launching.
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
    --downscale)
      DOWNSCALE="$2"
      DOWNSCALE_SET=1
      shift 2
      ;;
    --memory-profile)
      MEMORY_PROFILE="$2"
      shift 2
      ;;
    --blur-threshold)
      BLUR_THRESHOLD="$2"
      shift 2
      ;;
    --max-iters)
      MAX_ITERS="$2"
      shift 2
      ;;
    --vis)
      VIS="$2"
      shift 2
      ;;
    --extra-train-args)
      EXTRA_TRAIN_ARGS="$2"
      shift 2
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

if [[ -n "$MEMORY_PROFILE" && "$MEMORY_PROFILE" != "low" && "$MEMORY_PROFILE" != "medium" && "$MEMORY_PROFILE" != "high" ]]; then
  echo "Invalid --memory-profile: $MEMORY_PROFILE" >&2
  exit 1
fi

FRAME_STRIDE="${RTABMAP_FRAME_STRIDE:-}"
POINT_STRIDE="${RTABMAP_POINT_STRIDE:-}"
MAX_DEPTH_M="${RTABMAP_MAX_DEPTH_M:-}"
PREP_FORCE=0
if [[ -n "$MEMORY_PROFILE" ]]; then
  case "$MEMORY_PROFILE" in
    low)
      if [[ -z "$FRAME_STRIDE" ]]; then
        FRAME_STRIDE=3
      fi
      if [[ "$DOWNSCALE_SET" -eq 0 ]]; then
        DOWNSCALE=3
      fi
      ;;
    medium)
      if [[ -z "$FRAME_STRIDE" ]]; then
        FRAME_STRIDE=2
      fi
      if [[ "$DOWNSCALE_SET" -eq 0 ]]; then
        DOWNSCALE=2
      fi
      ;;
    high)
      if [[ -z "$FRAME_STRIDE" ]]; then
        FRAME_STRIDE=1
      fi
      if [[ "$DOWNSCALE_SET" -eq 0 ]]; then
        DOWNSCALE=1
      fi
      ;;
  esac

  if [[ "$MODE" == "prep" || "$MODE" == "prep-train" ]]; then
    PREP_FORCE=1
  fi
fi

if ! RUN_DIR="$(run_utils_resolve_run_dir_for_context "$REPO_ROOT" "$RUN_DIR" "trainable")"; then
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run directory not found: $RUN_DIR" >&2
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

train_extra_args="--max-num-iterations ${MAX_ITERS} --vis ${VIS}"
if [[ -n "$EXTRA_TRAIN_ARGS" ]]; then
  train_extra_args="${train_extra_args} ${EXTRA_TRAIN_ARGS}"
fi

run_cmd=(
  scripts/gaussian/run_handheld_prep_or_train.sh
  --run "$RUN_DIR"
  --mode "$MODE"
  --downscale "$DOWNSCALE"
  --blur-threshold "$BLUR_THRESHOLD"
)
if [[ "$USE_HOST" -eq 1 ]]; then
  run_cmd+=(--host)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: start_gaussian_training_job.sh"
  echo "Run: $RUN_DIR"
  echo "Mode: $MODE"
  if [[ -n "$MEMORY_PROFILE" ]]; then
    echo "Memory profile: $MEMORY_PROFILE"
    echo "RTAB-Map frame stride: $FRAME_STRIDE"
    echo "Force re-prepare: $PREP_FORCE"
  fi
  if [[ -n "$POINT_STRIDE" ]]; then
    echo "RTAB-Map point stride: $POINT_STRIDE"
  fi
  if [[ -n "$MAX_DEPTH_M" ]]; then
    echo "RTAB-Map max depth (m): $MAX_DEPTH_M"
  fi
  echo "Downscale: $DOWNSCALE"
  echo "Blur threshold: $BLUR_THRESHOLD"
  echo "Max iterations: $MAX_ITERS"
  echo "Vis: $VIS"
  echo "Backend: $TRAINING_BACKEND"
  echo "Train image: $TRAIN_IMAGE"
  echo "Launch mode: $([[ "$DETACH" -eq 1 ]] && echo detached || echo foreground)"
  echo "Executor: $([[ "$USE_HOST" -eq 1 ]] && echo host || echo docker)"
  echo "Command:"
  printf '  %q ' "${run_cmd[@]}"
  echo ""
  echo "Env TRAIN_EXTRA_ARGS:"
  echo "  $train_extra_args"
  exit 0
fi

mkdir -p "${RUN_DIR}/logs"

timestamp="$(date +%F_%H%M%S)"
log_file="${RUN_DIR}/logs/train_job_${timestamp}.log"
launcher="${RUN_DIR}/logs/train_job_${timestamp}.sh"
pid_file="${RUN_DIR}/logs/train_job.pid"
status_file="${RUN_DIR}/logs/train_job.status"

printf -v repo_root_q '%q' "$REPO_ROOT"
printf -v train_image_q '%q' "$TRAIN_IMAGE"
printf -v train_extra_args_q '%q' "$train_extra_args"
printf -v memory_profile_q '%q' "$MEMORY_PROFILE"
printf -v training_backend_q '%q' "$TRAINING_BACKEND"
printf -v frame_stride_q '%q' "$FRAME_STRIDE"
printf -v point_stride_q '%q' "$POINT_STRIDE"
printf -v max_depth_m_q '%q' "$MAX_DEPTH_M"
printf -v prep_force_q '%q' "$PREP_FORCE"
printf -v run_cmd_q '%q ' "${run_cmd[@]}"
printf -v run_dir_q '%q' "$RUN_DIR"
printf -v status_file_q '%q' "$status_file"
printf -v pid_file_q '%q' "$pid_file"
printf -v log_file_q '%q' "$log_file"
printf -v mode_q '%q' "$MODE"
printf -v launcher_q '%q' "$launcher"

cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

cd ${repo_root_q}
export TRAIN_IMAGE=${train_image_q}
export TRAIN_EXTRA_ARGS=${train_extra_args_q}
export MEMORY_PROFILE=${memory_profile_q}
export TRAINING_BACKEND=${training_backend_q}
export RTABMAP_FRAME_STRIDE=${frame_stride_q}
export RTABMAP_POINT_STRIDE=${point_stride_q}
export RTABMAP_MAX_DEPTH_M=${max_depth_m_q}
export GAUSSIAN_PREP_FORCE=${prep_force_q}

run_dir=${run_dir_q}
status_file=${status_file_q}
pid_file=${pid_file_q}
log_file=${log_file_q}
mode=${mode_q}
launcher_path=${launcher_q}
started_at="\$(date -Is)"

write_status_running() {
  cat > "\${status_file}" <<STATUS
state=running
run_dir=\${run_dir}
pid=\$$
started_at=\${started_at}
mode=\${mode}
backend=${training_backend_q}
memory_profile=${memory_profile_q}
log_file=\${log_file}
launcher=\${launcher_path}
STATUS
}

write_status_exit() {
  local code="\$1"
  local ended_at="\$2"
  cat > "\${status_file}" <<STATUS
state=exited
run_dir=\${run_dir}
pid=\$$
started_at=\${started_at}
ended_at=\${ended_at}
exit_code=\${code}
mode=\${mode}
backend=${training_backend_q}
memory_profile=${memory_profile_q}
log_file=\${log_file}
launcher=\${launcher_path}
STATUS
}

write_status_running

set +e
${run_cmd_q}
exit_code="\$?"
set -e

ended_at="\$(date -Is)"
write_status_exit "\${exit_code}" "\${ended_at}"

if [[ -f "\${pid_file}" ]] && [[ "\$(cat "\${pid_file}" 2>/dev/null || true)" == "\$$" ]]; then
  rm -f "\${pid_file}"
fi

exit "\${exit_code}"
LAUNCHER
chmod +x "$launcher"
ln -sfn "$(basename "$log_file")" "${RUN_DIR}/logs/train_job.latest.log"

if [[ "$DETACH" -eq 1 ]]; then
  if [[ -f "$pid_file" ]]; then
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && ps -p "$old_pid" >/dev/null 2>&1; then
      echo "A training job is already running for this run (PID $old_pid)."
      echo "Status: ./scripts/gaussian/training_job_status.sh --run $RUN_DIR"
      echo "Watch: ./scripts/gaussian/watch_gaussian_training_job.sh --run $RUN_DIR"
      echo "Stop:  ./scripts/gaussian/stop_gaussian_training_job.sh --run $RUN_DIR"
      exit 0
    fi
  fi

  nohup "$launcher" > "$log_file" 2>&1 &
  pid="$!"
  echo "$pid" > "$pid_file"
  sleep 0.1
  if ! ps -p "$pid" >/dev/null 2>&1; then
    wait "$pid" || true
    if [[ -f "$pid_file" ]] && [[ "$(cat "$pid_file" 2>/dev/null || true)" == "$pid" ]]; then
      rm -f "$pid_file"
    fi
  fi
  echo "Started training job."
  echo "PID: $pid"
  echo "Log: $log_file"
  echo "Status: ./scripts/gaussian/training_job_status.sh --run $RUN_DIR"
  echo "Watch: ./scripts/gaussian/watch_gaussian_training_job.sh --run $RUN_DIR"
  echo "Stop:  ./scripts/gaussian/stop_gaussian_training_job.sh --run $RUN_DIR"
else
  echo "Running in foreground."
  echo "Log: $log_file"
  set +e
  "$launcher" 2>&1 | tee "$log_file"
  exit_code="${PIPESTATUS[0]}"
  set -e
  if [[ "$exit_code" -ne 0 ]]; then
    echo "Training command exited with code $exit_code" >&2
    exit "$exit_code"
  fi
fi
