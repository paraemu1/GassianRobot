#!/usr/bin/env bash
set -euo pipefail

# Interactive terminal teleop for Create 3 over ROS 2.
# Uses teleop_twist_keyboard inside the RTAB-Map image.
#
# Usage:
#   ./scripts/teleop_keyboard.sh
#
# Optional overrides:
#   IMAGE_TAG=gassian/ros2-humble-rtabmap:latest
#   DDS_IFACE=l4tbr0
#   TOPIC_CMD_VEL=/cmd_vel
#   STOP_ON_EXIT=1

IMAGE_TAG="${IMAGE_TAG:-gassian/ros2-humble-rtabmap:latest}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}"
DDS_IFACE="${DDS_IFACE:-l4tbr0}"
TOPIC_CMD_VEL="${TOPIC_CMD_VEL:-/cmd_vel}"
STOP_ON_EXIT="${STOP_ON_EXIT:-1}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

stop_robot() {
  if [[ "$STOP_ON_EXIT" != "1" ]]; then
    return 0
  fi

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
    echo "Build it first: ./scripts/build_rtabmap_image.sh" >&2
    exit 1
  fi

  if ! ip link show "$DDS_IFACE" >/dev/null 2>&1; then
    echo "DDS interface not found: $DDS_IFACE" >&2
    echo "Set DDS_IFACE=<iface> if needed." >&2
    exit 1
  fi

  export CYCLONEDDS_URI="${CYCLONEDDS_URI:-<CycloneDDS><Domain><General><NetworkInterfaceAddress>${DDS_IFACE}</NetworkInterfaceAddress><DontRoute>true</DontRoute></General></Domain></CycloneDDS>}"

  echo "Starting interactive teleop on topic: $TOPIC_CMD_VEL"
  echo "Press Ctrl-C to exit."
  echo "A zero-velocity stop will be sent on exit."

  trap stop_robot EXIT

  docker run --rm -it --network host \
    -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY" \
    -e CYCLONEDDS_URI="$CYCLONEDDS_URI" \
    -e TOPIC_CMD_VEL="$TOPIC_CMD_VEL" \
    "$IMAGE_TAG" \
    bash -lc "source /opt/ros/humble/setup.bash && ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r cmd_vel:=\$TOPIC_CMD_VEL"
}

main "$@"
