#!/usr/bin/env bash
set -euo pipefail

# Arrow-keys-only teleop for iRobot Create 3.
# Movement keys: Up/Down/Left/Right only.
# Exit: q or Ctrl-C.

IMAGE_TAG="${IMAGE_TAG:-gassian/robot-runtime:latest}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}"
TOPIC_CMD_VEL="${TOPIC_CMD_VEL:-/cmd_vel}"
LINEAR_SPEED="${LINEAR_SPEED:-0.12}"
ANGULAR_SPEED="${ANGULAR_SPEED:-0.8}"
CMD_TIMEOUT="${CMD_TIMEOUT:-0.35}"
DEBUG_TELEOP="${DEBUG_TELEOP:-0}"
SHOW_BLOCK_STATUS="${SHOW_BLOCK_STATUS:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/teleop_arrow_keys.py"

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker and retry." >&2
  exit 1
fi

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "Docker image not found: $IMAGE_TAG" >&2
  echo "Build it first: ./scripts/build_robot_runtime_image.sh" >&2
  exit 1
fi

if [[ ! -f "$PY_SCRIPT" ]]; then
  echo "Missing required script: $PY_SCRIPT" >&2
  exit 1
fi

echo "Arrow-key teleop starting on topic: $TOPIC_CMD_VEL"
echo "Controls: Up=forward Down=reverse Left=rotate-left Right=rotate-right"
echo "Exit: q or Ctrl-C"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

docker run --rm -it --network host \
  -v "$PROJECT_ROOT:/robot_ws" \
  -w /robot_ws \
  -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION" \
  -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
  -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY" \
  -e TOPIC_CMD_VEL="$TOPIC_CMD_VEL" \
  -e LINEAR_SPEED="$LINEAR_SPEED" \
  -e ANGULAR_SPEED="$ANGULAR_SPEED" \
  -e CMD_TIMEOUT="$CMD_TIMEOUT" \
  -e DEBUG_TELEOP="$DEBUG_TELEOP" \
  -e SHOW_BLOCK_STATUS="$SHOW_BLOCK_STATUS" \
  "$IMAGE_TAG" \
  bash -lc "source /opt/ros/humble/setup.bash && python3 /robot_ws/scripts/teleop_arrow_keys.py"
