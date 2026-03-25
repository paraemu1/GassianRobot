#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

# Default raw topics for Create 3 + RPLIDAR + OAK-D Pro.
TF_TOPIC="${TF_TOPIC:-$GASSIAN_DEFAULT_TF_TOPIC}"
TF_STATIC_TOPIC="${TF_STATIC_TOPIC:-$GASSIAN_DEFAULT_TF_STATIC_TOPIC}"
ODOM_TOPIC="${ODOM_TOPIC:-$GASSIAN_DEFAULT_ODOM_TOPIC}"
SCAN_TOPIC="${SCAN_TOPIC:-$GASSIAN_DEFAULT_SCAN_TOPIC}"
RGB_TOPIC="${RGB_TOPIC:-$GASSIAN_DEFAULT_RGB_TOPIC}"
CAMERA_INFO_TOPIC="${CAMERA_INFO_TOPIC:-}"
DEPTH_TOPIC="${DEPTH_TOPIC:-}"
DEPTH_CAMERA_INFO_TOPIC="${DEPTH_CAMERA_INFO_TOPIC:-}"
TOPICS="${TOPICS:-}"
RUN_NAME="${RUN_NAME:-$(date +%F)-rtabmap_capture}"
OUT_DIR="${OUT_DIR:-runs/$RUN_NAME/raw}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
BAG_USE_QOS_OVERRIDES="${BAG_USE_QOS_OVERRIDES:-1}"
QOS_OVERRIDE_PATH="${QOS_OVERRIDE_PATH:-}"
PREFER_RUNNING_CONTAINER="${PREFER_RUNNING_CONTAINER:-$GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER}"

apply_autonomy_local_defaults

topic_exists() {
  local topic="$1"
  ros2 topic list | grep -Fxq "$topic"
}

select_depth_topic() {
  if [[ -n "$DEPTH_TOPIC" ]]; then
    printf "%s" "$DEPTH_TOPIC"
    return 0
  fi

  if topic_exists "$GASSIAN_ALT_DEPTH_TOPIC"; then
    printf "%s" "$GASSIAN_ALT_DEPTH_TOPIC"
    return 0
  fi

  if topic_exists "$GASSIAN_DEFAULT_DEPTH_TOPIC"; then
    printf "%s" "$GASSIAN_DEFAULT_DEPTH_TOPIC"
    return 0
  fi

  printf "%s" "$GASSIAN_DEFAULT_DEPTH_TOPIC"
}

if [[ -z "$CAMERA_INFO_TOPIC" ]]; then
  CAMERA_INFO_TOPIC="$(resolve_rgb_camera_info_topic "$RGB_TOPIC")"
fi

if [[ -z "$TOPICS" ]]; then
  TOPICS="$TF_TOPIC $TF_STATIC_TOPIC $ODOM_TOPIC $SCAN_TOPIC $RGB_TOPIC $CAMERA_INFO_TOPIC $DEPTH_TOPIC"
fi

if [[ "${IN_RECORD_RAW_BAG_CONTAINER:-0}" != "1" && "$PREFER_RUNNING_CONTAINER" == "1" ]] && ros_container_is_running "$ROS_CONTAINER"; then
  exec docker exec -i \
    -e IN_RECORD_RAW_BAG_CONTAINER=1 \
    -e TF_TOPIC="$TF_TOPIC" \
    -e TF_STATIC_TOPIC="$TF_STATIC_TOPIC" \
    -e ODOM_TOPIC="$ODOM_TOPIC" \
    -e SCAN_TOPIC="$SCAN_TOPIC" \
    -e RGB_TOPIC="$RGB_TOPIC" \
    -e CAMERA_INFO_TOPIC="$CAMERA_INFO_TOPIC" \
    -e DEPTH_TOPIC="$DEPTH_TOPIC" \
    -e DEPTH_CAMERA_INFO_TOPIC="$DEPTH_CAMERA_INFO_TOPIC" \
    -e TOPICS="$TOPICS" \
    -e RUN_NAME="$RUN_NAME" \
    -e OUT_DIR="$OUT_DIR" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e BAG_USE_QOS_OVERRIDES="$BAG_USE_QOS_OVERRIDES" \
    -e QOS_OVERRIDE_PATH="$QOS_OVERRIDE_PATH" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_CONTAINER" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/record_raw_bag.sh"
fi

if ! command -v ros2 >/dev/null 2>&1; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: ros2" >&2
    exit 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    echo "ros2 is not available on the host and container is not running: $ROS_CONTAINER" >&2
    echo "Start it first: ./scripts/run_robot_runtime_container.sh" >&2
    exit 1
  fi

  exec docker exec -i \
    -e IN_RECORD_RAW_BAG_CONTAINER=1 \
    -e TF_TOPIC="$TF_TOPIC" \
    -e TF_STATIC_TOPIC="$TF_STATIC_TOPIC" \
    -e ODOM_TOPIC="$ODOM_TOPIC" \
    -e SCAN_TOPIC="$SCAN_TOPIC" \
    -e RGB_TOPIC="$RGB_TOPIC" \
    -e CAMERA_INFO_TOPIC="$CAMERA_INFO_TOPIC" \
    -e DEPTH_TOPIC="$DEPTH_TOPIC" \
    -e DEPTH_CAMERA_INFO_TOPIC="$DEPTH_CAMERA_INFO_TOPIC" \
    -e TOPICS="$TOPICS" \
    -e RUN_NAME="$RUN_NAME" \
    -e OUT_DIR="$OUT_DIR" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e BAG_USE_QOS_OVERRIDES="$BAG_USE_QOS_OVERRIDES" \
    -e QOS_OVERRIDE_PATH="$QOS_OVERRIDE_PATH" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_CONTAINER" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/record_raw_bag.sh"
fi

if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
  ensure_dds_iface_exists "$DDS_IFACE"
fi

DEPTH_TOPIC="$(select_depth_topic)"

if [[ -z "$DEPTH_CAMERA_INFO_TOPIC" ]]; then
  if derived_depth_camera_info="$(derive_camera_info_topic_from_image_topic "$DEPTH_TOPIC" 2>/dev/null)"; then
    DEPTH_CAMERA_INFO_TOPIC="$derived_depth_camera_info"
  fi
fi

mkdir -p "$OUT_DIR"

read -r -a topic_array <<< "$TOPICS"

topic_in_array() {
  local wanted="$1"
  local topic
  for topic in "${topic_array[@]}"; do
    if [[ "$topic" == "$wanted" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ -n "$DEPTH_TOPIC" ]] && ! topic_in_array "$DEPTH_TOPIC"; then
  topic_array+=("$DEPTH_TOPIC")
fi

if [[ -n "$DEPTH_CAMERA_INFO_TOPIC" ]] && ! topic_in_array "$DEPTH_CAMERA_INFO_TOPIC"; then
  topic_array+=("$DEPTH_CAMERA_INFO_TOPIC")
fi

qos_override_path="$QOS_OVERRIDE_PATH"
cleanup_qos_override=0

append_sensor_qos_override() {
  local topic="$1"
  local depth="${2:-20}"

  cat <<EOF >> "$qos_override_path"
$topic:
  history: keep_last
  depth: $depth
  reliability: best_effort
  durability: volatile
  deadline:
    sec: 0
    nsec: 0
  lifespan:
    sec: 0
    nsec: 0
  liveliness: system_default
  liveliness_lease_duration:
    sec: 0
    nsec: 0
  avoid_ros_namespace_conventions: false
EOF
}

append_tf_static_qos_override() {
  cat <<EOF >> "$qos_override_path"
$TF_STATIC_TOPIC:
  history: keep_last
  depth: 1
  reliability: reliable
  durability: transient_local
  deadline:
    sec: 0
    nsec: 0
  lifespan:
    sec: 0
    nsec: 0
  liveliness: system_default
  liveliness_lease_duration:
    sec: 0
    nsec: 0
  avoid_ros_namespace_conventions: false
EOF
}

if [[ "$BAG_USE_QOS_OVERRIDES" == "1" && -z "$qos_override_path" ]]; then
  qos_override_path="$(mktemp)"
  cleanup_qos_override=1

  if topic_in_array "$SCAN_TOPIC"; then
    append_sensor_qos_override "$SCAN_TOPIC"
  fi
  if topic_in_array "$RGB_TOPIC"; then
    append_sensor_qos_override "$RGB_TOPIC"
  fi
  if topic_in_array "$CAMERA_INFO_TOPIC"; then
    append_sensor_qos_override "$CAMERA_INFO_TOPIC"
  fi
  if topic_in_array "$DEPTH_TOPIC"; then
    append_sensor_qos_override "$DEPTH_TOPIC"
  fi
  if [[ -n "$DEPTH_CAMERA_INFO_TOPIC" ]] && topic_in_array "$DEPTH_CAMERA_INFO_TOPIC"; then
    append_sensor_qos_override "$DEPTH_CAMERA_INFO_TOPIC"
  fi
  if topic_in_array "$TF_STATIC_TOPIC"; then
    append_tf_static_qos_override
  fi
fi

cleanup() {
  if [[ "$cleanup_qos_override" == "1" && -n "$qos_override_path" ]]; then
    rm -f "$qos_override_path"
  fi
}
trap cleanup EXIT

echo "Recording rosbag to: $OUT_DIR"
echo "Topics: ${topic_array[*]}"
if [[ -n "$qos_override_path" ]]; then
  echo "QoS overrides: $qos_override_path"
fi
echo "Press Ctrl+C to stop."

# MCAP storage keeps files compact and faster to index than sqlite by default.
record_cmd=(
  ros2 bag record
  --storage mcap
  --output "$OUT_DIR/rosbag"
)

if [[ -n "$qos_override_path" ]]; then
  record_cmd+=(--qos-profile-overrides-path "$qos_override_path")
fi

record_cmd+=("${topic_array[@]}")
"${record_cmd[@]}"
