#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
MODE="prep-train" # prep | train | prep-train
DOWNSCALE=2
BLUR_THRESHOLD=4
MAX_ITERS=30000
VIS="tensorboard"
EXTRA_TRAIN_ARGS=""
TRAIN_IMAGE="${TRAIN_IMAGE:-gassian/gsplat-train:jetson-compatible}"
DETACH=1
USE_HOST=0

usage() {
  cat <<'EOF'
Start a long-running Gaussian training job for an existing run.

Usage:
  ./scripts/start_gaussian_training_job.sh [--run <runs/YYYY-MM-DD-scene>|latest] [options]

Options:
  --run <path|latest>      Run directory. Default: latest.
  --mode <prep|train|prep-train>
                           prep-train by default.
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
  -h, --help               Show this help.
EOF
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

if ! RUN_DIR="$(run_utils_resolve_run_dir "$REPO_ROOT" "$RUN_DIR")"; then
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run directory not found: $RUN_DIR" >&2
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

mkdir -p "${RUN_DIR}/logs"

timestamp="$(date +%F_%H%M%S)"
log_file="${RUN_DIR}/logs/train_job_${timestamp}.log"
launcher="${RUN_DIR}/logs/train_job_${timestamp}.sh"
pid_file="${RUN_DIR}/logs/train_job.pid"

train_extra_args="--max-num-iterations ${MAX_ITERS} --vis ${VIS}"
if [[ -n "$EXTRA_TRAIN_ARGS" ]]; then
  train_extra_args="${train_extra_args} ${EXTRA_TRAIN_ARGS}"
fi

run_cmd=(
  scripts/run_handheld_prep_or_train.sh
  --run "$RUN_DIR"
  --mode "$MODE"
  --downscale "$DOWNSCALE"
  --blur-threshold "$BLUR_THRESHOLD"
)
if [[ "$USE_HOST" -eq 1 ]]; then
  run_cmd+=(--host)
fi

printf -v repo_root_q '%q' "$REPO_ROOT"
printf -v train_image_q '%q' "$TRAIN_IMAGE"
printf -v train_extra_args_q '%q' "$train_extra_args"
printf -v run_cmd_q '%q ' "${run_cmd[@]}"

cat > "$launcher" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${repo_root_q}
export TRAIN_IMAGE=${train_image_q}
export TRAIN_EXTRA_ARGS=${train_extra_args_q}
exec ${run_cmd_q}
EOF
chmod +x "$launcher"
ln -sfn "$(basename "$log_file")" "${RUN_DIR}/logs/train_job.latest.log"

if [[ "$DETACH" -eq 1 ]]; then
  if [[ -f "$pid_file" ]]; then
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && ps -p "$old_pid" >/dev/null 2>&1; then
      echo "A training job is already running for this run (PID $old_pid)." >&2
      echo "Stop it first: ./scripts/stop_gaussian_training_job.sh --run $RUN_DIR" >&2
      exit 1
    fi
  fi

  nohup "$launcher" > "$log_file" 2>&1 &
  pid="$!"
  echo "$pid" > "$pid_file"
  echo "Started training job."
  echo "PID: $pid"
  echo "Log: $log_file"
  echo "Watch: ./scripts/watch_gaussian_training_job.sh --run $RUN_DIR"
  echo "Stop:  ./scripts/stop_gaussian_training_job.sh --run $RUN_DIR"
else
  echo "Running in foreground."
  echo "Log: $log_file"
  "$launcher" 2>&1 | tee "$log_file"
fi
