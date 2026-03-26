#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

ROBOT_IP="${ROBOT_IP:-192.168.186.2}"
ROBOT_IMAGE="${ROBOT_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}"
ROBOT_RMW_IMPLEMENTATION="${ROBOT_RMW_IMPLEMENTATION:-$GASSIAN_DEFAULT_RMW_IMPLEMENTATION}"
ROBOT_ROS_DOMAIN_ID="${ROBOT_ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_ROS_DOMAIN_ID}"
ROBOT_ROS_LOCALHOST_ONLY="${ROBOT_ROS_LOCALHOST_ONLY:-$GASSIAN_DEFAULT_ROS_LOCALHOST_ONLY}"
ROBOT_DDS_IFACE="${ROBOT_DDS_IFACE:-$GASSIAN_DEFAULT_DDS_IFACE}"
ROBOT_DDS_INCLUDE_LOOPBACK="${ROBOT_DDS_INCLUDE_LOOPBACK:-$GASSIAN_DEFAULT_DDS_INCLUDE_LOOPBACK}"
ROBOT_CYCLONEDDS_URI="${ROBOT_CYCLONEDDS_URI:-}"
STOP_STATUS_TIMEOUT_SEC="${STOP_STATUS_TIMEOUT_SEC:-6}"
CLIFF_TIMEOUT_SEC="${CLIFF_TIMEOUT_SEC:-6}"
CLIFF_LOW_ABS_THRESHOLD="${CLIFF_LOW_ABS_THRESHOLD:-200}"
CLIFF_LOW_RATIO_THRESHOLD="${CLIFF_LOW_RATIO_THRESHOLD:-0.20}"
CLIFF_MAX_REFERENCE_THRESHOLD="${CLIFF_MAX_REFERENCE_THRESHOLD:-1000}"
EXIT_STOPPED=10
EXIT_CLIFF_UNSAFE=11
EXIT_STOPPED_AND_CLIFF_UNSAFE=12

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

status_field() {
  local field="$1"
  local content="$2"

  printf '%s\n' "$content" | awk -v field="$field" '$1 == field ":" {print tolower($2); exit}'
}

read_stop_status() {
  robot_ros "timeout '${STOP_STATUS_TIMEOUT_SEC}' ros2 topic echo --once /stop_status"
}

read_cliff_intensity() {
  robot_ros "timeout '${CLIFF_TIMEOUT_SEC}' ros2 topic echo --once /cliff_intensity --qos-reliability best_effort"
}

parse_cliff_pairs() {
  printf '%s\n' "$1" | awk '
    /frame_id: cliff_/ {
      frame = $2
    }
    /value:/ {
      if (frame != "") {
        printf "%s=%s\n", frame, $2
        frame = ""
      }
    }'
}

cliff_summary() {
  printf '%s\n' "$1" | awk '
    BEGIN {
      first = 1
    }
    {
      split($0, parts, "=")
      if (!first) {
        printf " "
      }
      printf "%s=%s", parts[1], parts[2]
      first = 0
    }'
}

cliff_unsafe_reason() {
  awk \
    -v low_abs="$CLIFF_LOW_ABS_THRESHOLD" \
    -v low_ratio="$CLIFF_LOW_RATIO_THRESHOLD" \
    -v max_ref="$CLIFF_MAX_REFERENCE_THRESHOLD" '
    BEGIN {
      min_value = -1
      max_value = -1
    }
    {
      split($0, parts, "=")
      frame = parts[1]
      value = parts[2] + 0.0
      if (min_value < 0 || value < min_value) {
        min_value = value
        min_frame = frame
      }
      if (max_value < 0 || value > max_value) {
        max_value = value
        max_frame = frame
      }
    }
    END {
      if (max_value < 0) {
        exit 1
      }

      if (max_value >= max_ref && (min_value <= low_abs || min_value <= (max_value * low_ratio))) {
        printf "%s=%s max=%s", min_frame, min_value, max_value
        exit 0
      }

      exit 1
    }'
}

require_cmd docker
require_cmd ping
require_cmd timeout

ensure_create3_usb_host_iface "$ROBOT_DDS_IFACE"
ensure_dds_iface_exists "$ROBOT_DDS_IFACE"

if ! ping -I "$ROBOT_DDS_IFACE" -c 1 -W 1 "$ROBOT_IP" >/dev/null 2>&1; then
  echo "[FAIL] Create3 is unreachable on ${ROBOT_DDS_IFACE} (${ROBOT_IP})" >&2
  exit 1
fi

stop_output="$(read_stop_status)"
is_stopped="$(status_field "is_stopped" "$stop_output")"
if [[ -z "$is_stopped" ]]; then
  echo "[FAIL] Could not parse /stop_status output" >&2
  printf '%s\n' "$stop_output" >&2
  exit 1
fi

cliff_output="$(read_cliff_intensity)"
cliff_pairs="$(parse_cliff_pairs "$cliff_output")"
if [[ -z "$cliff_pairs" ]]; then
  echo "[FAIL] Could not parse /cliff_intensity output" >&2
  printf '%s\n' "$cliff_output" >&2
  exit 1
fi

cliff_text="$(cliff_summary "$cliff_pairs")"
unsafe_cliff_reason=""
if unsafe_cliff_reason="$(printf '%s\n' "$cliff_pairs" | cliff_unsafe_reason)"; then
  :
else
  unsafe_cliff_reason=""
fi

if [[ -n "$unsafe_cliff_reason" ]]; then
  if [[ "$is_stopped" == "true" ]]; then
    echo "[FAIL] stop_status indicates the Create3 base is stopped and the cliff readings are unsafe" >&2
    echo "[INFO] cliff readings look unsafe (${unsafe_cliff_reason}); the robot is likely partly on the dock or at an edge." >&2
    echo "[INFO] cliff_intensity ${cliff_text}" >&2
    exit "$EXIT_STOPPED_AND_CLIFF_UNSAFE"
  fi
  echo "[FAIL] cliff readings look unsafe for autonomous motion (${unsafe_cliff_reason})" >&2
  echo "[INFO] cliff_intensity ${cliff_text}" >&2
  echo "[INFO] Re-seat the robot fully on the dock or place it flat on the floor before retrying." >&2
  exit "$EXIT_CLIFF_UNSAFE"
fi

if [[ "$is_stopped" == "true" ]]; then
  echo "[INFO] stop_status is_stopped=true (robot is stationary, but cliff readings are safe)"
else
  echo "[PASS] Create3 motion-ready: stop_status=false"
fi
echo "[PASS] cliff_intensity ${cliff_text}"
