#!/usr/bin/env bash
set -euo pipefail

# Jetson quick path:
# 1) Create run folder
# 2) Capture short RGB video from V4L2 camera
# 3) Extract image frames from capture
# 4) Train + export Gaussian splat using existing pipeline
#
# Example:
# ./scripts/capture_and_train_from_camera.sh --scene lab_quicktest --duration 20 --downscale 2

SCENE_NAME=""
RUN_DIR=""
DEVICE="${DEVICE:-/dev/video0}"
SOURCE="${SOURCE:-auto}" # auto | oak | v4l2 | csi
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
DURATION="${DURATION:-20}"
FRAME_SAMPLE_FPS="${FRAME_SAMPLE_FPS:-3}"
DOWNSCALE="${DOWNSCALE:-2}"
USE_HOST=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage:"
  echo "  $0 --scene <scene_name> [--duration seconds] [--downscale N] [--host]"
  echo "  $0 --run <runs/YYYY-MM-DD-scene> [--duration seconds] [--downscale N] [--host]"
  echo ""
  echo "Flags:"
  echo "  --scene <name>          create run with scripts/init_run_dir.sh"
  echo "  --run <path>            use existing run directory"
  echo "  --device <path>         camera device (default: /dev/video0)"
  echo "  --source <auto|oak|v4l2|csi> capture backend (default: auto)"
  echo "  --width <px>            capture width (default: 1280)"
  echo "  --height <px>           capture height (default: 720)"
  echo "  --fps <n>               capture FPS (default: 30)"
  echo "  --duration <seconds>    capture duration (default: 20)"
  echo "  --frame-sample-fps <n>  extracted JPG FPS from video (default: 3)"
  echo "  --downscale <N>         ns-process-data downscale factor (default: 2)"
  echo "  --host                  run training tools on host instead of Docker"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scene)
      SCENE_NAME="$2"
      shift 2
      ;;
    --run)
      RUN_DIR="$2"
      shift 2
      ;;
    --device)
      DEVICE="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --width)
      WIDTH="$2"
      shift 2
      ;;
    --height)
      HEIGHT="$2"
      shift 2
      ;;
    --fps)
      FPS="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --frame-sample-fps)
      FRAME_SAMPLE_FPS="$2"
      shift 2
      ;;
    --downscale)
      DOWNSCALE="$2"
      shift 2
      ;;
    --host)
      USE_HOST=1
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

if [[ -z "$SCENE_NAME" && -z "$RUN_DIR" ]]; then
  echo "Provide either --scene or --run."
  usage
  exit 1
fi

if [[ -n "$SCENE_NAME" && -n "$RUN_DIR" ]]; then
  echo "Use one of --scene or --run, not both."
  usage
  exit 1
fi

for cmd in ffmpeg realpath; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done

if [[ "$SOURCE" != "auto" && "$SOURCE" != "oak" && "$SOURCE" != "v4l2" && "$SOURCE" != "csi" ]]; then
  echo "Invalid --source: $SOURCE"
  usage
  exit 1
fi

if [[ "$SOURCE" == "auto" ]]; then
  if python3 - <<'PY' >/dev/null 2>&1
import depthai as dai
raise SystemExit(0 if len(dai.Device.getAllAvailableDevices()) > 0 else 1)
PY
  then
    SOURCE="oak"
  elif [[ -e "$DEVICE" ]]; then
    SOURCE="v4l2"
  elif command -v gst-launch-1.0 >/dev/null 2>&1; then
    SOURCE="csi"
  else
    echo "Could not auto-detect a capture backend."
    echo "No camera device at $DEVICE and gst-launch-1.0 not available."
    exit 1
  fi
fi

if [[ "$SOURCE" == "v4l2" && ! -e "$DEVICE" ]]; then
  echo "Camera device not found for v4l2 source: $DEVICE"
  exit 1
fi

if [[ -n "$SCENE_NAME" ]]; then
  "${REPO_ROOT}/scripts/init_run_dir.sh" "$SCENE_NAME"
  RUN_DIR="${REPO_ROOT}/runs/$(date +%F)-${SCENE_NAME}"
fi

RUN_DIR="$(realpath -m "$RUN_DIR")"
mkdir -p "${RUN_DIR}/raw/images" "${RUN_DIR}/logs"

CAPTURE_MP4="${RUN_DIR}/raw/capture.mp4"
FRAMES_DIR="${RUN_DIR}/raw/images"

echo "[1/4] Capturing camera video to ${CAPTURE_MP4}"
if [[ "$SOURCE" == "oak" ]]; then
  "${REPO_ROOT}/scripts/record_oak_rgb_video.sh" \
    --output "$CAPTURE_MP4" \
    --duration "$DURATION" \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --fps "$FPS" \
    2>&1 | tee "${RUN_DIR}/logs/oak-depthai-capture.log"
elif [[ "$SOURCE" == "v4l2" ]]; then
  ffmpeg -y \
    -f v4l2 \
    -framerate "$FPS" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -i "$DEVICE" \
    -t "$DURATION" \
    "$CAPTURE_MP4" \
    2>&1 | tee "${RUN_DIR}/logs/ffmpeg-capture.log"
else
  if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    echo "Missing required command for CSI source: gst-launch-1.0"
    exit 1
  fi
  NUM_BUFFERS=$((FPS * DURATION))
  gst-launch-1.0 -e \
    nvarguscamerasrc sensor-id=0 num-buffers="$NUM_BUFFERS" \
    ! "video/x-raw(memory:NVMM),width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
    ! nvvidconv \
    ! nvv4l2h264enc \
    ! h264parse \
    ! qtmux \
    ! filesink location="$CAPTURE_MP4" \
    2>&1 | tee "${RUN_DIR}/logs/gstreamer-capture.log"
fi

echo "[2/4] Extracting sampled images to ${FRAMES_DIR}"
ffmpeg -y \
  -i "$CAPTURE_MP4" \
  -vf "fps=${FRAME_SAMPLE_FPS}" \
  "${FRAMES_DIR}/frame_%05d.jpg" \
  2>&1 | tee "${RUN_DIR}/logs/ffmpeg-extract-frames.log"

echo "[3/4] Writing gs_input.env"
"${REPO_ROOT}/scripts/prepare_gs_input_from_run.sh" --run "$RUN_DIR"

echo "[4/4] Processing + training + export"
if [[ "$USE_HOST" -eq 1 ]]; then
  "${REPO_ROOT}/scripts/process_train_export.sh" \
    --run "$RUN_DIR" \
    --from-run-env \
    --downscale "$DOWNSCALE" \
    --host
else
  "${REPO_ROOT}/scripts/process_train_export.sh" \
    --run "$RUN_DIR" \
    --from-run-env \
    --downscale "$DOWNSCALE"
fi

echo "Finished run: $RUN_DIR"
echo "Captured frames: ${FRAMES_DIR}"
echo "Exported splat: ${RUN_DIR}/exports/splat"
