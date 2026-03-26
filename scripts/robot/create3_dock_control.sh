#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

ACTION="${1:-status}"
ROBOT_IP="${ROBOT_IP:-192.168.186.2}"
ROBOT_IMAGE="${ROBOT_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}"
ROBOT_RMW_IMPLEMENTATION="${ROBOT_RMW_IMPLEMENTATION:-$GASSIAN_DEFAULT_RMW_IMPLEMENTATION}"
ROBOT_ROS_DOMAIN_ID="${ROBOT_ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_ROS_DOMAIN_ID}"
ROBOT_ROS_LOCALHOST_ONLY="${ROBOT_ROS_LOCALHOST_ONLY:-$GASSIAN_DEFAULT_ROS_LOCALHOST_ONLY}"
ROBOT_DDS_IFACE="${ROBOT_DDS_IFACE:-$GASSIAN_DEFAULT_DDS_IFACE}"
ROBOT_DDS_INCLUDE_LOOPBACK="${ROBOT_DDS_INCLUDE_LOOPBACK:-$GASSIAN_DEFAULT_DDS_INCLUDE_LOOPBACK}"
ROBOT_CYCLONEDDS_URI="${ROBOT_CYCLONEDDS_URI:-}"
DOCK_STATUS_TIMEOUT_SEC="${DOCK_STATUS_TIMEOUT_SEC:-8}"
DOCK_ACTION_TIMEOUT_SEC="${DOCK_ACTION_TIMEOUT_SEC:-120}"
DOCK_READY_TIMEOUT_SEC="${DOCK_READY_TIMEOUT_SEC:-120}"
DOCK_RETRY_SEC="${DOCK_RETRY_SEC:-2}"
UNDOCK_ACTION_TIMEOUT_SEC="${UNDOCK_ACTION_TIMEOUT_SEC:-30}"
UNDOCK_READY_TIMEOUT_SEC="${UNDOCK_READY_TIMEOUT_SEC:-45}"
UNDOCK_RETRY_SEC="${UNDOCK_RETRY_SEC:-2}"

if [[ -z "$ROBOT_CYCLONEDDS_URI" && "$ROBOT_RMW_IMPLEMENTATION" == "rmw_cyclonedds_cpp" ]]; then
  ROBOT_CYCLONEDDS_URI="$(build_cyclonedds_uri "$ROBOT_DDS_IFACE" "$ROBOT_DDS_INCLUDE_LOOPBACK")"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

robot_ros() {
  local cmd="$1"

  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="$ROBOT_RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROBOT_ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROBOT_ROS_LOCALHOST_ONLY" \
    -e CYCLONEDDS_URI="$ROBOT_CYCLONEDDS_URI" \
    "$ROBOT_IMAGE" \
    bash -lc "source /opt/ros/humble/setup.bash && ${cmd}"
}

read_dock_status() {
  robot_ros "timeout '${DOCK_STATUS_TIMEOUT_SEC}' ros2 topic echo --once /dock_status"
}

status_field() {
  local field="$1"
  local content="$2"

  printf '%s\n' "$content" | awk -v field="$field" '$1 == field ":" {print tolower($2); exit}'
}

ensure_robot_link() {
  require_cmd docker
  require_cmd ping
  require_cmd timeout

  ensure_create3_usb_host_iface "$ROBOT_DDS_IFACE"
  ensure_dds_iface_exists "$ROBOT_DDS_IFACE"

  if ! ping -I "$ROBOT_DDS_IFACE" -c 1 -W 1 "$ROBOT_IP" >/dev/null 2>&1; then
    echo "Create3 is unreachable on ${ROBOT_DDS_IFACE} (${ROBOT_IP})" >&2
    exit 1
  fi
}

print_status() {
  local content
  local dock_visible
  local is_docked

  content="$(read_dock_status)"
  dock_visible="$(status_field "dock_visible" "$content")"
  is_docked="$(status_field "is_docked" "$content")"

  [[ -n "$dock_visible" ]] || dock_visible="unknown"
  [[ -n "$is_docked" ]] || is_docked="unknown"

  printf "dock_visible=%s\n" "$dock_visible"
  printf "is_docked=%s\n" "$is_docked"
}

wait_until_undocked() {
  local deadline=$((SECONDS + UNDOCK_READY_TIMEOUT_SEC))
  local attempt=1

  while (( SECONDS < deadline )); do
    local content
    local is_docked

    content="$(read_dock_status)"
    is_docked="$(status_field "is_docked" "$content")"
    if [[ "$is_docked" == "false" ]]; then
      printf '%s\n' "$content"
      return 0
    fi

    echo "Still docked after undock request (attempt ${attempt}); retrying in ${UNDOCK_RETRY_SEC}s" >&2
    attempt=$((attempt + 1))
    sleep "$UNDOCK_RETRY_SEC"
  done

  return 1
}

wait_until_docked() {
  local deadline=$((SECONDS + DOCK_READY_TIMEOUT_SEC))
  local attempt=1

  while (( SECONDS < deadline )); do
    local content
    local is_docked

    content="$(read_dock_status)"
    is_docked="$(status_field "is_docked" "$content")"
    if [[ "$is_docked" == "true" ]]; then
      printf '%s\n' "$content"
      return 0
    fi

    echo "Still undocked after dock request (attempt ${attempt}); retrying in ${DOCK_RETRY_SEC}s" >&2
    attempt=$((attempt + 1))
    sleep "$DOCK_RETRY_SEC"
  done

  return 1
}

run_dock() {
  local content
  local dock_visible
  local is_docked
  local output

  content="$(read_dock_status)"
  dock_visible="$(status_field "dock_visible" "$content")"
  is_docked="$(status_field "is_docked" "$content")"
  if [[ "$is_docked" == "true" ]]; then
    echo "Create3 is already docked."
    printf '%s\n' "$content"
    return 0
  fi

  if [[ "$dock_visible" != "true" ]]; then
    echo "Dock is not currently visible. Create3 will search its immediate surroundings and may fail if it is too far from the dock." >&2
  fi

  echo "Create3 is undocked. Sending /dock action..."
  output="$(robot_ros "timeout '${DOCK_ACTION_TIMEOUT_SEC}' ros2 action send_goal /dock irobot_create_msgs/action/Dock '{}'" 2>&1 || true)"
  printf '%s\n' "$output"

  if ! wait_until_docked >/tmp/create3_dock_status_after_dock.out 2>&1; then
    echo "Create3 did not report docked within ${DOCK_READY_TIMEOUT_SEC}s." >&2
    sed -n '1,80p' /tmp/create3_dock_status_after_dock.out >&2 || true
    exit 1
  fi

  echo "Create3 docked successfully."
  sed -n '1,20p' /tmp/create3_dock_status_after_dock.out
}

run_undock() {
  local content
  local is_docked
  local output

  content="$(read_dock_status)"
  is_docked="$(status_field "is_docked" "$content")"
  if [[ "$is_docked" == "false" ]]; then
    echo "Create3 is already undocked."
    printf '%s\n' "$content"
    return 0
  fi

  echo "Create3 is docked. Sending /undock action..."
  output="$(robot_ros "timeout '${UNDOCK_ACTION_TIMEOUT_SEC}' ros2 action send_goal /undock irobot_create_msgs/action/Undock '{}'" 2>&1 || true)"
  printf '%s\n' "$output"

  if ! wait_until_undocked >/tmp/create3_dock_status_after_undock.out 2>&1; then
    echo "Create3 did not report undocked within ${UNDOCK_READY_TIMEOUT_SEC}s." >&2
    sed -n '1,80p' /tmp/create3_dock_status_after_undock.out >&2 || true
    exit 1
  fi

  echo "Create3 undocked successfully."
  sed -n '1,20p' /tmp/create3_dock_status_after_undock.out
}

ensure_robot_link

case "$ACTION" in
  status)
    print_status
    ;;
  dock)
    run_dock
    ;;
  undock)
    run_undock
    ;;
  *)
    echo "Usage: $0 {status|dock|undock}" >&2
    exit 2
    ;;
esac
