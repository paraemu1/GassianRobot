#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-gassian/robot-runtime:latest}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}"
DDS_IFACE="${DDS_IFACE:-}"
TOPIC_CMD_VEL="${TOPIC_CMD_VEL:-/cmd_vel}"
GAMECUBE_HIDRAW="${GAMECUBE_HIDRAW:-}"
GAMECUBE_PORT="${GAMECUBE_PORT:-0}"
LINEAR_MAX="${LINEAR_MAX:-0.20}"
ANGULAR_MAX="${ANGULAR_MAX:-1.2}"
CMD_TIMEOUT="${CMD_TIMEOUT:-0.25}"
DEADMAN_BUTTON="${DEADMAN_BUTTON:-A}"
TURBO_BUTTON="${TURBO_BUTTON:-R}"
GAMECUBE_DEADZONE="${GAMECUBE_DEADZONE:-0.14}"
ALLOW_REVERSE="${ALLOW_REVERSE:-1}"
USE_C_STICK_TURN="${USE_C_STICK_TURN:-0}"
STATUS_HZ="${STATUS_HZ:-5.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY_SCRIPT="/robot_ws/scripts/robot/teleop_gamecube_hidraw.py"
ADAPTER_HID_ID="0003:00000079:00001844"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

detect_hidraw_device() {
  local sysfs
  for sysfs in /sys/class/hidraw/hidraw*; do
    [[ -e "${sysfs}/device/uevent" ]] || continue
    if grep -q "^HID_ID=${ADAPTER_HID_ID}\$" "${sysfs}/device/uevent"; then
      echo "/dev/$(basename "$sysfs")"
      return 0
    fi
  done
  return 1
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
  require_cmd grep
  require_cmd ip

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi

  if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Docker image not found: $IMAGE_TAG" >&2
    echo "Build it first: ./scripts/build/build_robot_runtime_image.sh" >&2
    exit 1
  fi

  if [[ -z "$GAMECUBE_HIDRAW" ]]; then
    GAMECUBE_HIDRAW="$(detect_hidraw_device || true)"
  fi

  if [[ -z "$GAMECUBE_HIDRAW" ]]; then
    echo "Nintendo/Mayflash GameCube adapter (057e:0337) not found under /sys/class/hidraw." >&2
    echo "If you know the node, retry with GAMECUBE_HIDRAW=/dev/hidrawN." >&2
    exit 1
  fi

  if [[ ! -e "$GAMECUBE_HIDRAW" ]]; then
    echo "Missing HID device: $GAMECUBE_HIDRAW" >&2
    echo "Tip: the adapter node may change after replug. Retry with GAMECUBE_HIDRAW=/dev/hidrawN." >&2
    exit 1
  fi

  if [[ -n "$DDS_IFACE" ]]; then
    if ! ip link show "$DDS_IFACE" >/dev/null 2>&1; then
      echo "DDS interface not found: $DDS_IFACE" >&2
      echo "Set DDS_IFACE=<iface> if needed." >&2
      exit 1
    fi
  fi

  if [[ ! -f "${PROJECT_ROOT}/scripts/robot/teleop_gamecube_hidraw.py" ]]; then
    echo "Missing script: ${PROJECT_ROOT}/scripts/robot/teleop_gamecube_hidraw.py" >&2
    exit 1
  fi

  if [[ "${RMW_IMPLEMENTATION}" == "rmw_cyclonedds_cpp" && -n "$DDS_IFACE" ]]; then
    export CYCLONEDDS_URI="${CYCLONEDDS_URI:-<CycloneDDS><Domain><General><Interfaces><NetworkInterface name=\"${DDS_IFACE}\" multicast=\"default\" /></Interfaces><DontRoute>true</DontRoute></General></Domain></CycloneDDS>}"
  else
    export CYCLONEDDS_URI="${CYCLONEDDS_URI:-}"
  fi

  echo "Starting GameCube teleop on topic: $TOPIC_CMD_VEL"
  echo "device=$GAMECUBE_HIDRAW port=$((GAMECUBE_PORT + 1)) deadman=$DEADMAN_BUTTON turbo=$TURBO_BUTTON"
  echo "Release the deadman button to stop. Ctrl-C also sends repeated zero-velocity stop commands."

  trap stop_robot EXIT

  docker run --rm -it --network host \
    --device "$GAMECUBE_HIDRAW:$GAMECUBE_HIDRAW" \
    -v "$PROJECT_ROOT:/robot_ws" \
    -w /robot_ws \
    -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY" \
    -e CYCLONEDDS_URI="$CYCLONEDDS_URI" \
    -e TOPIC_CMD_VEL="$TOPIC_CMD_VEL" \
    -e GAMECUBE_HIDRAW="$GAMECUBE_HIDRAW" \
    -e GAMECUBE_PORT="$GAMECUBE_PORT" \
    -e LINEAR_MAX="$LINEAR_MAX" \
    -e ANGULAR_MAX="$ANGULAR_MAX" \
    -e CMD_TIMEOUT="$CMD_TIMEOUT" \
    -e DEADMAN_BUTTON="$DEADMAN_BUTTON" \
    -e TURBO_BUTTON="$TURBO_BUTTON" \
    -e GAMECUBE_DEADZONE="$GAMECUBE_DEADZONE" \
    -e ALLOW_REVERSE="$ALLOW_REVERSE" \
    -e USE_C_STICK_TURN="$USE_C_STICK_TURN" \
    -e STATUS_HZ="$STATUS_HZ" \
    "$IMAGE_TAG" \
    bash -lc "source /opt/ros/humble/setup.bash && python3 '${PY_SCRIPT}'"
}

main "$@"
