#!/usr/bin/env bash
set -euo pipefail

# Improved Create 3 manual drive app (Docker + ROS2).
# Uses teleop_drive_app.py for robust key handling, deadman timeout,
# estop latch, speed tuning, and status HUD.

IMAGE_TAG="${IMAGE_TAG:-gassian/robot-runtime:latest}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}"
DDS_IFACE="${DDS_IFACE:-l4tbr0}"
TOPIC_CMD_VEL="${TOPIC_CMD_VEL:-/cmd_vel}"
LINEAR_SPEED="${LINEAR_SPEED:-0.12}"
ANGULAR_SPEED="${ANGULAR_SPEED:-0.8}"
CMD_TIMEOUT="${CMD_TIMEOUT:-0.35}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PY_SCRIPT="/robot_ws/scripts/teleop_drive_app.py"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

stop_robot() {
  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY" \
    -e CYCLONEDDS_URI="$CYCLONEDDS_URI" \
    "$IMAGE_TAG" \
    bash -lc "source /opt/ros/humble/setup.bash && timeout 4 ros2 topic pub --once --wait-matching-subscriptions 1 '$TOPIC_CMD_VEL' geometry_msgs/msg/Twist '{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}' >/dev/null" \
    >/dev/null 2>&1 || true
}

main() {
  require_cmd docker
  require_cmd ip

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi

  if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Docker image not found: $IMAGE_TAG" >&2
    echo "Build it first: ./scripts/build_robot_runtime_image.sh" >&2
    exit 1
  fi

  if [[ ! -f "${PROJECT_ROOT}/scripts/teleop_drive_app.py" ]]; then
    echo "Missing script: ${PROJECT_ROOT}/scripts/teleop_drive_app.py" >&2
    exit 1
  fi

  if ! ip link show "$DDS_IFACE" >/dev/null 2>&1; then
    echo "DDS interface not found: $DDS_IFACE" >&2
    echo "Set DDS_IFACE=<iface> if needed." >&2
    exit 1
  fi

  if [[ "${RMW_IMPLEMENTATION}" == "rmw_cyclonedds_cpp" ]]; then
    export CYCLONEDDS_URI="${CYCLONEDDS_URI:-<CycloneDDS><Domain><General><NetworkInterfaceAddress>${DDS_IFACE}</NetworkInterfaceAddress><DontRoute>true</DontRoute></General></Domain></CycloneDDS>}"
  else
    export CYCLONEDDS_URI="${CYCLONEDDS_URI:-}"
  fi

  echo "Starting improved drive app on topic: $TOPIC_CMD_VEL"
  echo "DDS_IFACE=$DDS_IFACE RMW=$RMW_IMPLEMENTATION DOMAIN=$ROS_DOMAIN_ID"
  echo "Exit with q or Ctrl-C. Zero-velocity stop is sent on exit."

  trap stop_robot EXIT

  docker run --rm -it --network host \
    -v "$PROJECT_ROOT:/robot_ws" \
    -w /robot_ws \
    -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY" \
    -e CYCLONEDDS_URI="$CYCLONEDDS_URI" \
    -e TOPIC_CMD_VEL="$TOPIC_CMD_VEL" \
    -e LINEAR_SPEED="$LINEAR_SPEED" \
    -e ANGULAR_SPEED="$ANGULAR_SPEED" \
    -e CMD_TIMEOUT="$CMD_TIMEOUT" \
    "$IMAGE_TAG" \
    bash -lc "source /opt/ros/humble/setup.bash && python3 '${PY_SCRIPT}'"
}

main "$@"
