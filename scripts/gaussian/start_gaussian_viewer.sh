#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/_run_utils.sh"

RUN_DIR=""
PORT=7007
TRAIN_IMAGE="${TRAIN_IMAGE:-gassian/gsplat-train:jetson-compatible}"
CONTAINER_NAME=""
DRY_RUN=0
OPEN_BROWSER=0
BROWSER_WAIT_SEC="${BROWSER_WAIT_SEC:-180}"

detect_tailscale_ipv4() {
  local ip_addr=""

  if command -v tailscale >/dev/null 2>&1; then
    ip_addr="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$ip_addr" ]] && command -v ip >/dev/null 2>&1; then
    ip_addr="$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1 || true)"
  fi

  if [[ -n "$ip_addr" ]]; then
    printf "%s\n" "$ip_addr"
  fi
}

usage() {
  cat <<'USAGE'
Start a web viewer for a trained Gaussian run.

Usage:
  ./scripts/gaussian/start_gaussian_viewer.sh [--run <runs/YYYY-MM-DD-scene>|latest] [options]

Options:
  --run <path|latest>      Run directory. Default: latest viewer-ready run.
  --port <N>               Viewer port on host (default: 7007).
  --train-image <tag>      Docker image tag (default: gassian/gsplat-train:jetson-compatible).
  --container-name <name>  Optional custom container name.
  --open-browser           Wait for the viewer port, then print the remote access URL to open from your Tailscale-connected machine.
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
    --open-browser)
      OPEN_BROWSER=1
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

latest_config=""
latest_model_dir=""
while IFS= read -r config_path; do
  model_dir="$(dirname "$config_path")/nerfstudio_models"
  if [[ -d "$model_dir" ]]; then
    latest_config="$config_path"
    latest_model_dir="$model_dir"
  fi
done < <(find "${RUN_DIR}/checkpoints" -name config.yml 2>/dev/null | sort)

if [[ -z "$latest_config" ]]; then
  echo "No trained viewer checkpoint found under ${RUN_DIR}/checkpoints." >&2
  echo "Expected both:" >&2
  echo "  - checkpoints/**/config.yml" >&2
  echo "  - checkpoints/**/nerfstudio_models/" >&2
  echo "This usually means training exited before the first checkpoint was saved." >&2
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
TAILSCALE_IP="$(detect_tailscale_ipv4 || true)"

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
  if [[ -n "$TAILSCALE_IP" ]]; then
    echo "Tailscale URL: http://${TAILSCALE_IP}:${PORT}"
  else
    echo "Tailscale URL: unavailable (no Tailscale IPv4 detected)"
  fi
  if [[ "$OPEN_BROWSER" -eq 1 ]]; then
    echo "Remote access: would wait for the viewer and print the remote URL."
  fi
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

sleep 2
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx 'true'; then
  echo "Viewer container exited before opening the port." >&2
  echo "Recent logs:" >&2
  docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
  exit 1
fi

echo "Viewer container started: $CONTAINER_NAME"
echo "Logs:      docker logs -f ${CONTAINER_NAME}"

if [[ "$OPEN_BROWSER" -eq 1 ]]; then
  echo "Viewer is still loading. Wait for the final 'Viewer ready' line before opening it."
  echo "This can take a minute or two on this Jetson."

  if command -v python3 >/dev/null 2>&1; then
    set +e
    python3 - "$PORT" "$BROWSER_WAIT_SEC" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
timeout = float(sys.argv[2])
deadline = time.time() + timeout
while time.time() < deadline:
    with socket.socket() as sock:
        sock.settimeout(1.0)
        try:
            sock.connect(("127.0.0.1", port))
            sys.exit(0)
        except OSError:
            time.sleep(0.5)
sys.exit(1)
PY
    wait_code="$?"
    set -e
  else
    wait_code=1
  fi

  if [[ "${wait_code:-1}" -eq 0 ]]; then
    echo "Local URL: http://localhost:${PORT}"
    echo "LAN URL:   http://<jetson-ip>:${PORT}"
    if [[ -n "$TAILSCALE_IP" ]]; then
      echo "Tailscale URL: http://${TAILSCALE_IP}:${PORT}"
      echo "Viewer ready. Open this from your Tailscale-connected machine: http://${TAILSCALE_IP}:${PORT}"
    else
      echo "Tailscale URL: unavailable (no Tailscale IPv4 detected)"
      echo "Viewer ready. Open this URL from your remote machine: http://<jetson-ip>:${PORT}"
    fi
  else
    echo "Viewer did not become reachable within ${BROWSER_WAIT_SEC}s." >&2
    echo "Recent logs:" >&2
    docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
    if [[ -n "$TAILSCALE_IP" ]]; then
      echo "Expected Tailscale URL when ready: http://${TAILSCALE_IP}:${PORT}" >&2
    else
      echo "Expected remote URL when ready: http://<jetson-ip>:${PORT}" >&2
    fi
    exit 1
  fi
else
  echo "Viewer is starting. It may take a minute before the port responds."
  echo "Use --open-browser if you want this script to wait until it is actually reachable."
  echo "Expected Local URL when ready: http://localhost:${PORT}"
  echo "Expected LAN URL when ready:   http://<jetson-ip>:${PORT}"
  if [[ -n "$TAILSCALE_IP" ]]; then
    echo "Expected Tailscale URL when ready: http://${TAILSCALE_IP}:${PORT}"
  else
    echo "Expected Tailscale URL when ready: unavailable (no Tailscale IPv4 detected)"
  fi
fi
