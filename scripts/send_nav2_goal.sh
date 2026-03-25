#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

# Send a simple Nav2 goal in map frame.
# Usage:
#   ./scripts/send_nav2_goal.sh 1.5 0.0 0.0 1.0
#   (x y z_w w quaternion defaults to x=0 y=0 z=0 w=1)

X="${1:-0.0}"
Y="${2:-0.0}"
QZ="${3:-0.0}"
QW="${4:-1.0}"
FRAME_ID="${FRAME_ID:-map}"
ACTION_NAME="${ACTION_NAME:-/navigate_to_pose}"
WAIT_SEC="${WAIT_SEC:-20}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
PREFER_RUNNING_CONTAINER="${PREFER_RUNNING_CONTAINER:-$GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER}"

apply_autonomy_local_defaults

run_in_container() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: docker" >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi

  if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
    ensure_dds_iface_exists "$DDS_IFACE"
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    exec docker exec -i \
      -e IN_SEND_NAV2_GOAL_CONTAINER=1 \
      -e FRAME_ID="$FRAME_ID" \
      -e ACTION_NAME="$ACTION_NAME" \
      -e WAIT_SEC="$WAIT_SEC" \
      -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
      -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
      -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
      "$ROS_CONTAINER" \
      bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/send_nav2_goal.sh '$X' '$Y' '$QZ' '$QW'"
  fi

  if ! docker image inspect "$ROS_IMAGE" >/dev/null 2>&1; then
    echo "Docker image not found: $ROS_IMAGE" >&2
    echo "Build it first: ./scripts/build_robot_runtime_image.sh" >&2
    exit 1
  fi

  exec docker run --rm --network host \
    -v "${REPO_ROOT}:${CONTAINER_WORKDIR}:ro" \
    -e IN_SEND_NAV2_GOAL_CONTAINER=1 \
    -e ROS_IMAGE="$ROS_IMAGE" \
    -e ROS_CONTAINER="$ROS_CONTAINER" \
    -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY" \
    -e DDS_IFACE="$DDS_IFACE" \
    -e DDS_INCLUDE_LOOPBACK="$DDS_INCLUDE_LOOPBACK" \
    -e CYCLONEDDS_URI="$CYCLONEDDS_URI" \
    -e FRAME_ID="$FRAME_ID" \
    -e ACTION_NAME="$ACTION_NAME" \
    -e WAIT_SEC="$WAIT_SEC" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_IMAGE" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/send_nav2_goal.sh '$X' '$Y' '$QZ' '$QW'"
}

if [[ "${IN_SEND_NAV2_GOAL_CONTAINER:-0}" != "1" && "$PREFER_RUNNING_CONTAINER" == "1" ]] && ros_container_is_running "$ROS_CONTAINER"; then
  run_in_container
fi

if ! command -v ros2 >/dev/null 2>&1 && [[ "${IN_SEND_NAV2_GOAL_CONTAINER:-0}" != "1" ]]; then
  run_in_container
fi

if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
  ensure_dds_iface_exists "$DDS_IFACE"
fi

if ! ros2 action list | grep -Fxq "$ACTION_NAME"; then
  echo "Nav2 action not available: $ACTION_NAME" >&2
  echo "Is Nav2 running?" >&2
  exit 1
fi

exec ros2 action send_goal "$ACTION_NAME" nav2_msgs/action/NavigateToPose \
  "{pose: {header: {frame_id: $FRAME_ID}, pose: {position: {x: $X, y: $Y, z: 0.0}, orientation: {z: $QZ, w: $QW}}}}" \
  --feedback
