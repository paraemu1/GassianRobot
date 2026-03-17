#!/usr/bin/env bash
set -euo pipefail

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

ROS_CONTAINER="${ROS_CONTAINER:-ros_humble_rtabmap}"
ROS_IMAGE="${ROS_IMAGE:-gassian/ros2-humble-rtabmap:latest}"

ros_cmd() {
  if command -v ros2 >/dev/null 2>&1; then
    ros2 "$@"
    return
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    docker exec -i "$ROS_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && ros2 $*"
    return
  fi

  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}" \
    -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
    -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
    "$ROS_IMAGE" bash -lc "source /opt/ros/humble/setup.bash && ros2 $*"
}

if ! ros_cmd action list | grep -Fxq "$ACTION_NAME"; then
  echo "Nav2 action not available: $ACTION_NAME" >&2
  echo "Is Nav2 running?" >&2
  exit 1
fi

ros_cmd action send_goal "$ACTION_NAME" nav2_msgs/action/NavigateToPose \
  "{pose: {header: {frame_id: $FRAME_ID}, pose: {position: {x: $X, y: $Y, z: 0.0}, orientation: {z: $QZ, w: $QW}}}}" \
  --feedback
