#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

RGB_TOPIC="${RGB_TOPIC:-$GASSIAN_DEFAULT_RGB_TOPIC}"
CAMERA_INFO_TOPIC="${CAMERA_INFO_TOPIC:-}"
DEPTH_TOPIC="${DEPTH_TOPIC:-}"
ODOM_TOPIC="${ODOM_TOPIC:-$GASSIAN_DEFAULT_ODOM_TOPIC}"
ODOM_FRAME_ID="${ODOM_FRAME_ID:-odom}"
FRAME_ID="${FRAME_ID:-$GASSIAN_DEFAULT_RTABMAP_FRAME_ID}"
MAP_FRAME="${MAP_FRAME:-map}"
DURATION_SEC="${DURATION_SEC:-10}"
MIN_RGB_SAMPLES="${MIN_RGB_SAMPLES:-10}"
MAX_RGB_CAMERA_INFO_SLOP_SEC="${MAX_RGB_CAMERA_INFO_SLOP_SEC:-0.05}"
MAX_RGB_DEPTH_SLOP_SEC="${MAX_RGB_DEPTH_SLOP_SEC:-$GASSIAN_DEFAULT_RTABMAP_APPROX_SYNC_MAX_INTERVAL}"
MAX_RGB_ODOM_SLOP_SEC="${MAX_RGB_ODOM_SLOP_SEC:-0.10}"
CHECK_TF_READY="${CHECK_TF_READY:-1}"
CHECK_MAP_ODOM_TF="${CHECK_MAP_ODOM_TF:-0}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
PREFER_RUNNING_CONTAINER="${PREFER_RUNNING_CONTAINER:-$GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER}"

apply_autonomy_local_defaults

ODOM_FRAME_ID="$(normalize_frame_id "$ODOM_FRAME_ID")"
FRAME_ID="$(normalize_frame_id "$FRAME_ID")"
MAP_FRAME="$(normalize_frame_id "$MAP_FRAME")"

topic_exists() {
  local topic="$1"
  ros2 topic list | awk -v topic="$topic" '$0 == topic { found=1 } END { exit found ? 0 : 1 }'
}

select_depth_topic() {
  if [[ -n "$DEPTH_TOPIC" ]]; then
    printf "%s" "$DEPTH_TOPIC"
    return 0
  fi

  if command -v ros2 >/dev/null 2>&1; then
    if topic_exists "$GASSIAN_ALT_DEPTH_TOPIC"; then
      printf "%s" "$GASSIAN_ALT_DEPTH_TOPIC"
      return 0
    fi

    if topic_exists "$GASSIAN_DEFAULT_DEPTH_TOPIC"; then
      printf "%s" "$GASSIAN_DEFAULT_DEPTH_TOPIC"
      return 0
    fi
  fi

  printf "%s" "$GASSIAN_DEFAULT_DEPTH_TOPIC"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run_in_container() {
  require_cmd docker

  if ! ros_container_is_running "$ROS_CONTAINER"; then
    echo "Robot runtime container is not running: $ROS_CONTAINER" >&2
    echo "Start it first: ./scripts/robot/run_robot_runtime_container.sh" >&2
    exit 1
  fi

  exec docker exec -i \
    -e IN_CHECK_RTABMAP_SYNC_CONTAINER=1 \
    -e ODOM_TOPIC="$ODOM_TOPIC" \
    -e RGB_TOPIC="$RGB_TOPIC" \
    -e CAMERA_INFO_TOPIC="$CAMERA_INFO_TOPIC" \
    -e DEPTH_TOPIC="$DEPTH_TOPIC" \
    -e ODOM_FRAME_ID="$ODOM_FRAME_ID" \
    -e FRAME_ID="$FRAME_ID" \
    -e MAP_FRAME="$MAP_FRAME" \
    -e DURATION_SEC="$DURATION_SEC" \
    -e MIN_RGB_SAMPLES="$MIN_RGB_SAMPLES" \
    -e MAX_RGB_CAMERA_INFO_SLOP_SEC="$MAX_RGB_CAMERA_INFO_SLOP_SEC" \
    -e MAX_RGB_DEPTH_SLOP_SEC="$MAX_RGB_DEPTH_SLOP_SEC" \
    -e MAX_RGB_ODOM_SLOP_SEC="$MAX_RGB_ODOM_SLOP_SEC" \
    -e CHECK_TF_READY="$CHECK_TF_READY" \
    -e CHECK_MAP_ODOM_TF="$CHECK_MAP_ODOM_TF" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_CONTAINER" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/robot/check_rtabmap_sync.sh"
}

if [[ -z "$CAMERA_INFO_TOPIC" ]]; then
  CAMERA_INFO_TOPIC="$(resolve_rgb_camera_info_topic "$RGB_TOPIC")"
fi

if [[ "${IN_CHECK_RTABMAP_SYNC_CONTAINER:-0}" != "1" && "$PREFER_RUNNING_CONTAINER" == "1" ]] && ros_container_is_running "$ROS_CONTAINER"; then
  run_in_container
fi

if ! command -v ros2 >/dev/null 2>&1; then
  run_in_container
fi

require_cmd python3

if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
  ensure_dds_iface_exists "$DDS_IFACE"
fi

DEPTH_TOPIC="$(select_depth_topic)"

exec python3 "${SCRIPT_DIR}/check_rtabmap_sync.py" \
  --odom-topic "$ODOM_TOPIC" \
  --rgb-topic "$RGB_TOPIC" \
  --camera-info-topic "$CAMERA_INFO_TOPIC" \
  --depth-topic "$DEPTH_TOPIC" \
  --odom-frame "$ODOM_FRAME_ID" \
  --base-frame "$FRAME_ID" \
  --map-frame "$MAP_FRAME" \
  --duration-sec "$DURATION_SEC" \
  --min-rgb-samples "$MIN_RGB_SAMPLES" \
  --max-rgb-camera-info-slop-sec "$MAX_RGB_CAMERA_INFO_SLOP_SEC" \
  --max-rgb-depth-slop-sec "$MAX_RGB_DEPTH_SLOP_SEC" \
  --max-rgb-odom-slop-sec "$MAX_RGB_ODOM_SLOP_SEC" \
  --check-tf-ready "$CHECK_TF_READY" \
  --check-map-odom-tf "$CHECK_MAP_ODOM_TF"
