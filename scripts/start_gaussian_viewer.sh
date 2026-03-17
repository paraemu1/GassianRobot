#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_run_utils.sh"

RUN_DIR=""
PORT=7007
TRAIN_IMAGE="${TRAIN_IMAGE:-gassian/gsplat-train:jetson-compatible}"
CONTAINER_NAME=""
DRY_RUN=0

usage() {
  cat <<'USAGE'
Start a web viewer for a trained Gaussian run.

Usage:
  ./scripts/start_gaussian_viewer.sh [--run <runs/YYYY-MM-DD-scene>|latest] [options]

Options:
  --run <path|latest>      Run directory. Default: latest viewer-ready run.
  --port <N>               Viewer port on host (default: 7007).
  --train-image <tag>      Docker image tag (default: gassian/gsplat-train:jetson-compatible).
  --container-name <name>  Optional custom container name.
  --dry-run                Validate inputs and print container launch command.
  -h, --help               Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --train-image)
      TRAIN_IMAGE="$2"
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

if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: docker" >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi
fi

if ! RUN_DIR="$(run_utils_resolve_run_dir_for_context "$REPO_ROOT" "$RUN_DIR" "viewer_ready")"; then
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "Run directory not found: $RUN_DIR" >&2
  run_utils_list_runs "$REPO_ROOT" >&2
  exit 1
fi

latest_config="$(find "${RUN_DIR}/checkpoints" -name config.yml | sort | tail -n1 || true)"
if [[ -z "$latest_config" ]]; then
  echo "No config.yml found under ${RUN_DIR}/checkpoints." >&2
  exit 1
fi

if [[ "$latest_config" != "${REPO_ROOT}"/* ]]; then
  echo "Run must be inside repo for Docker mode: $RUN_DIR" >&2
  exit 1
fi

rel_config="${latest_config#${REPO_ROOT}/}"
run_slug="$(basename "$RUN_DIR" | tr -cs 'a-zA-Z0-9' '_')"
if [[ -z "$CONTAINER_NAME" ]]; then
  CONTAINER_NAME="gs_viewer_${run_slug}"
fi

preamble_cmd="python3 -m pip uninstall -y opencv-python opencv-python-headless >/dev/null 2>&1 || true; rm -rf /usr/local/lib/python3.8/dist-packages/cv2 /usr/local/lib/python3.8/dist-packages/cv2.*; python3 -m pip install --no-cache-dir opencv-python-headless==4.8.1.78 >/dev/null"
viewer_cmd="${preamble_cmd}; ns-viewer --load-config /workspace/${rel_config} --viewer.websocket-host 0.0.0.0 --viewer.websocket-port ${PORT}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: start_gaussian_viewer.sh"
  echo "Run: $RUN_DIR"
  echo "Config: $latest_config"
  echo "Container: $CONTAINER_NAME"
  echo "Train image: $TRAIN_IMAGE"
  echo "Port: $PORT"
  echo "Viewer command:"
  echo "  $viewer_cmd"
  echo "Local URL: http://localhost:${PORT}"
  echo "LAN URL:   http://<jetson-ip>:${PORT}"
  exit 0
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  --ipc host \
  --runtime nvidia \
  -v "${REPO_ROOT}:/workspace" \
  -w /workspace \
  "$TRAIN_IMAGE" \
  bash -lc "$viewer_cmd" >/dev/null

echo "Viewer container started: $CONTAINER_NAME"
echo "Local URL: http://localhost:${PORT}"
echo "LAN URL:   http://<jetson-ip>:${PORT}"
echo "Logs:      docker logs -f ${CONTAINER_NAME}"
