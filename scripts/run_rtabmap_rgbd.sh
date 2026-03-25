#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

RGB_TOPIC="${RGB_TOPIC:-$GASSIAN_DEFAULT_RGB_TOPIC}"
CAMERA_INFO_TOPIC="${CAMERA_INFO_TOPIC:-}"
DEPTH_TOPIC="${DEPTH_TOPIC:-}"
ODOM_TOPIC="${ODOM_TOPIC:-$GASSIAN_DEFAULT_ODOM_TOPIC}"
ODOM_FRAME_ID="${ODOM_FRAME_ID:-odom}"
FRAME_ID="${FRAME_ID:-$GASSIAN_DEFAULT_RTABMAP_FRAME_ID}"
RTABMAP_VIZ="${RTABMAP_VIZ:-$GASSIAN_DEFAULT_RTABMAP_VIZ}"
RVIZ="${RVIZ:-$GASSIAN_DEFAULT_RVIZ}"
VISUAL_ODOMETRY="${VISUAL_ODOMETRY:-$GASSIAN_DEFAULT_VISUAL_ODOMETRY}"
RTABMAP_ARGS="${RTABMAP_ARGS:-$GASSIAN_DEFAULT_RTABMAP_ARGS}"
DELETE_DB_ON_START="${DELETE_DB_ON_START:-true}"
RTABMAP_DB_PATH="${RTABMAP_DB_PATH:-}"
QOS="${QOS:-$GASSIAN_DEFAULT_RTABMAP_QOS}"
APPROX_SYNC="${APPROX_SYNC:-$GASSIAN_DEFAULT_RTABMAP_APPROX_SYNC}"
TOPIC_QUEUE_SIZE="${TOPIC_QUEUE_SIZE:-$GASSIAN_DEFAULT_RTABMAP_TOPIC_QUEUE_SIZE}"
SYNC_QUEUE_SIZE="${SYNC_QUEUE_SIZE:-$GASSIAN_DEFAULT_RTABMAP_SYNC_QUEUE_SIZE}"
APPROX_SYNC_MAX_INTERVAL="${APPROX_SYNC_MAX_INTERVAL:-$GASSIAN_DEFAULT_RTABMAP_APPROX_SYNC_MAX_INTERVAL}"
WAIT_FOR_TRANSFORM="${WAIT_FOR_TRANSFORM:-0.5}"
WAIT_FOR_CAMERA_READY="${WAIT_FOR_CAMERA_READY:-true}"
CAMERA_READY_TIMEOUT_SEC="${CAMERA_READY_TIMEOUT_SEC:-30}"
CAMERA_READY_ECHO_TIMEOUT_SEC="${CAMERA_READY_ECHO_TIMEOUT_SEC:-4}"
CAMERA_READY_RETRY_SEC="${CAMERA_READY_RETRY_SEC:-2}"
WAIT_FOR_ODOM_READY="${WAIT_FOR_ODOM_READY:-auto}"
ODOM_READY_TIMEOUT_SEC="${ODOM_READY_TIMEOUT_SEC:-20}"
ODOM_READY_ECHO_TIMEOUT_SEC="${ODOM_READY_ECHO_TIMEOUT_SEC:-4}"
ODOM_READY_RETRY_SEC="${ODOM_READY_RETRY_SEC:-2}"
START_ODOM_NAV2_BRIDGE="${START_ODOM_NAV2_BRIDGE:-true}"
NAV2_ODOM_TOPIC="${NAV2_ODOM_TOPIC:-/odom_nav2}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
PREFER_RUNNING_CONTAINER="${PREFER_RUNNING_CONTAINER:-$GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER}"

apply_autonomy_local_defaults

normalize_bool() {
  case "${1,,}" in
    true|1|yes|on) echo "True" ;;
    false|0|no|off) echo "False" ;;
    *)
      echo "Invalid boolean value: $1" >&2
      exit 1
      ;;
  esac
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_rtabmap_param_arg() {
  local args="$1"
  local key="$2"
  local value="$3"

  if [[ " $args " == *" --$key "* ]]; then
    printf "%s" "$args"
    return 0
  fi

  if [[ -n "$args" ]]; then
    printf "%s --%s %s" "$args" "$key" "$value"
    return 0
  fi

  printf -- "--%s %s" "$key" "$value"
}

remove_rtabmap_arg() {
  local args="$1"
  local key="$2"
  local stripped=""
  local token

  # shellcheck disable=SC2206
  local parts=( $args )
  for token in "${parts[@]}"; do
    if [[ "$token" == "$key" ]]; then
      continue
    fi
    if [[ -n "$stripped" ]]; then
      stripped+=" "
    fi
    stripped+="$token"
  done

  printf "%s" "$stripped"
}

containerize_repo_path() {
  local path="$1"

  if [[ "$path" == "$REPO_ROOT/"* ]]; then
    printf "%s/%s" "$CONTAINER_WORKDIR" "${path#$REPO_ROOT/}"
    return 0
  fi

  printf "%s" "$path"
}

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

wait_for_camera_inputs() {
  local deadline=$((SECONDS + CAMERA_READY_TIMEOUT_SEC))
  local attempt=1

  require_cmd timeout

  while (( SECONDS < deadline )); do
    local -a missing_topics=()
    local topic
    for topic in "$RGB_TOPIC" "$CAMERA_INFO_TOPIC" "$DEPTH_TOPIC"; do
      if ! timeout "$CAMERA_READY_ECHO_TIMEOUT_SEC" ros2 topic echo --once "$topic" >/dev/null 2>&1; then
        missing_topics+=("$topic")
      fi
    done

    if [[ ${#missing_topics[@]} -eq 0 ]]; then
      return 0
    fi

    echo "Waiting for live OAK topics (attempt ${attempt}): ${missing_topics[*]}" >&2
    attempt=$((attempt + 1))
    sleep "$CAMERA_READY_RETRY_SEC"
  done

  echo "Timed out waiting for live OAK topics: $RGB_TOPIC $CAMERA_INFO_TOPIC $DEPTH_TOPIC" >&2
  return 1
}

resolve_wait_for_odom_ready() {
  case "${WAIT_FOR_ODOM_READY,,}" in
    auto)
      if [[ "${VISUAL_ODOMETRY,,}" == "true" || "${VISUAL_ODOMETRY,,}" == "1" || "${VISUAL_ODOMETRY,,}" == "yes" || "${VISUAL_ODOMETRY,,}" == "on" ]]; then
        echo "False"
      else
        echo "True"
      fi
      ;;
    *)
      normalize_bool "$WAIT_FOR_ODOM_READY"
      ;;
  esac
}

wait_for_odom_input() {
  local deadline=$((SECONDS + ODOM_READY_TIMEOUT_SEC))
  local attempt=1

  require_cmd timeout

  while (( SECONDS < deadline )); do
    if timeout "$ODOM_READY_ECHO_TIMEOUT_SEC" ros2 topic echo --once "$ODOM_TOPIC" >/dev/null 2>&1; then
      return 0
    fi

    echo "Waiting for local odom (attempt ${attempt}): ${ODOM_TOPIC}" >&2
    attempt=$((attempt + 1))
    sleep "$ODOM_READY_RETRY_SEC"
  done

  echo "Timed out waiting for local odom on ${ODOM_TOPIC}" >&2
  echo "Start ./scripts/run_create3_odom_bridge.sh start or use VISUAL_ODOMETRY=true if you intentionally want RTAB-Map VO." >&2
  return 1
}

WAIT_FOR_CAMERA_READY="$(normalize_bool "$WAIT_FOR_CAMERA_READY")"
WAIT_FOR_ODOM_READY="$(resolve_wait_for_odom_ready)"
START_ODOM_NAV2_BRIDGE="$(normalize_bool "$START_ODOM_NAV2_BRIDGE")"
DELETE_DB_ON_START="$(normalize_bool "$DELETE_DB_ON_START")"
ODOM_FRAME_ID="$(normalize_frame_id "$ODOM_FRAME_ID")"
FRAME_ID="$(normalize_frame_id "$FRAME_ID")"

start_odom_nav2_bridge() {
  local bridge_script="${SCRIPT_DIR}/rtabmap_odom_nav2_bridge.py"
  local bridge_log="/tmp/rtabmap_odom_nav2_bridge.log"

  require_cmd nohup
  require_cmd python3

  if [[ ! -f "$bridge_script" ]]; then
    echo "Missing odom bridge script: $bridge_script" >&2
    exit 1
  fi

  pkill -f "$bridge_script" >/dev/null 2>&1 || true
  nohup python3 "$bridge_script" \
    --source-topic "$ODOM_TOPIC" \
    --relay-topic "$NAV2_ODOM_TOPIC" \
    --default-odom-frame "$ODOM_FRAME_ID" \
    --default-base-frame "$FRAME_ID" \
    >"$bridge_log" 2>&1 &
}

if [[ -z "$CAMERA_INFO_TOPIC" ]]; then
  CAMERA_INFO_TOPIC="$(resolve_rgb_camera_info_topic "$RGB_TOPIC")"
fi

if [[ -n "$RTABMAP_DB_PATH" ]]; then
  RTABMAP_DB_PATH="$(containerize_repo_path "$RTABMAP_DB_PATH")"
fi

if [[ "${IN_RTABMAP_RGBD_CONTAINER:-0}" != "1" && "$PREFER_RUNNING_CONTAINER" == "1" ]] && ros_container_is_running "$ROS_CONTAINER"; then
  exec docker exec -i \
    -e IN_RTABMAP_RGBD_CONTAINER=1 \
    -e RGB_TOPIC="$RGB_TOPIC" \
    -e CAMERA_INFO_TOPIC="$CAMERA_INFO_TOPIC" \
    -e DEPTH_TOPIC="$DEPTH_TOPIC" \
    -e ODOM_TOPIC="$ODOM_TOPIC" \
    -e ODOM_FRAME_ID="$ODOM_FRAME_ID" \
    -e FRAME_ID="$FRAME_ID" \
    -e RTABMAP_VIZ="$RTABMAP_VIZ" \
    -e RVIZ="$RVIZ" \
    -e VISUAL_ODOMETRY="$VISUAL_ODOMETRY" \
    -e RTABMAP_ARGS="$RTABMAP_ARGS" \
    -e DELETE_DB_ON_START="$DELETE_DB_ON_START" \
    -e RTABMAP_DB_PATH="$RTABMAP_DB_PATH" \
    -e QOS="$QOS" \
    -e APPROX_SYNC="$APPROX_SYNC" \
    -e TOPIC_QUEUE_SIZE="$TOPIC_QUEUE_SIZE" \
    -e SYNC_QUEUE_SIZE="$SYNC_QUEUE_SIZE" \
    -e APPROX_SYNC_MAX_INTERVAL="$APPROX_SYNC_MAX_INTERVAL" \
    -e WAIT_FOR_TRANSFORM="$WAIT_FOR_TRANSFORM" \
    -e WAIT_FOR_CAMERA_READY="$WAIT_FOR_CAMERA_READY" \
    -e CAMERA_READY_TIMEOUT_SEC="$CAMERA_READY_TIMEOUT_SEC" \
    -e CAMERA_READY_ECHO_TIMEOUT_SEC="$CAMERA_READY_ECHO_TIMEOUT_SEC" \
    -e CAMERA_READY_RETRY_SEC="$CAMERA_READY_RETRY_SEC" \
    -e WAIT_FOR_ODOM_READY="$WAIT_FOR_ODOM_READY" \
    -e ODOM_READY_TIMEOUT_SEC="$ODOM_READY_TIMEOUT_SEC" \
    -e ODOM_READY_ECHO_TIMEOUT_SEC="$ODOM_READY_ECHO_TIMEOUT_SEC" \
    -e ODOM_READY_RETRY_SEC="$ODOM_READY_RETRY_SEC" \
    -e START_ODOM_NAV2_BRIDGE="$START_ODOM_NAV2_BRIDGE" \
    -e NAV2_ODOM_TOPIC="$NAV2_ODOM_TOPIC" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_CONTAINER" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/run_rtabmap_rgbd.sh"
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
    -e IN_RTABMAP_RGBD_CONTAINER=1 \
    -e RGB_TOPIC="$RGB_TOPIC" \
    -e CAMERA_INFO_TOPIC="$CAMERA_INFO_TOPIC" \
    -e DEPTH_TOPIC="$DEPTH_TOPIC" \
    -e ODOM_TOPIC="$ODOM_TOPIC" \
    -e ODOM_FRAME_ID="$ODOM_FRAME_ID" \
    -e FRAME_ID="$FRAME_ID" \
    -e RTABMAP_VIZ="$RTABMAP_VIZ" \
    -e RVIZ="$RVIZ" \
    -e VISUAL_ODOMETRY="$VISUAL_ODOMETRY" \
    -e RTABMAP_ARGS="$RTABMAP_ARGS" \
    -e DELETE_DB_ON_START="$DELETE_DB_ON_START" \
    -e RTABMAP_DB_PATH="$RTABMAP_DB_PATH" \
    -e QOS="$QOS" \
    -e APPROX_SYNC="$APPROX_SYNC" \
    -e TOPIC_QUEUE_SIZE="$TOPIC_QUEUE_SIZE" \
    -e SYNC_QUEUE_SIZE="$SYNC_QUEUE_SIZE" \
    -e APPROX_SYNC_MAX_INTERVAL="$APPROX_SYNC_MAX_INTERVAL" \
    -e WAIT_FOR_TRANSFORM="$WAIT_FOR_TRANSFORM" \
    -e WAIT_FOR_CAMERA_READY="$WAIT_FOR_CAMERA_READY" \
    -e CAMERA_READY_TIMEOUT_SEC="$CAMERA_READY_TIMEOUT_SEC" \
    -e CAMERA_READY_ECHO_TIMEOUT_SEC="$CAMERA_READY_ECHO_TIMEOUT_SEC" \
    -e CAMERA_READY_RETRY_SEC="$CAMERA_READY_RETRY_SEC" \
    -e WAIT_FOR_ODOM_READY="$WAIT_FOR_ODOM_READY" \
    -e ODOM_READY_TIMEOUT_SEC="$ODOM_READY_TIMEOUT_SEC" \
    -e ODOM_READY_ECHO_TIMEOUT_SEC="$ODOM_READY_ECHO_TIMEOUT_SEC" \
    -e ODOM_READY_RETRY_SEC="$ODOM_READY_RETRY_SEC" \
    -e START_ODOM_NAV2_BRIDGE="$START_ODOM_NAV2_BRIDGE" \
    -e NAV2_ODOM_TOPIC="$NAV2_ODOM_TOPIC" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_CONTAINER" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/run_rtabmap_rgbd.sh"
fi

if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
  ensure_dds_iface_exists "$DDS_IFACE"
fi

DEPTH_TOPIC="$(select_depth_topic)"

if [[ "$DEPTH_TOPIC" == "$GASSIAN_DEFAULT_DEPTH_TOPIC" ]]; then
  if [[ "$APPROX_SYNC_MAX_INTERVAL" == "$GASSIAN_DEFAULT_RTABMAP_APPROX_SYNC_MAX_INTERVAL" ]]; then
    APPROX_SYNC_MAX_INTERVAL="$GASSIAN_FALLBACK_STEREO_RTABMAP_APPROX_SYNC_MAX_INTERVAL"
  fi
  if [[ "$TOPIC_QUEUE_SIZE" == "$GASSIAN_DEFAULT_RTABMAP_TOPIC_QUEUE_SIZE" ]]; then
    TOPIC_QUEUE_SIZE="$GASSIAN_FALLBACK_STEREO_RTABMAP_TOPIC_QUEUE_SIZE"
  fi
  if [[ "$SYNC_QUEUE_SIZE" == "$GASSIAN_DEFAULT_RTABMAP_SYNC_QUEUE_SIZE" ]]; then
    SYNC_QUEUE_SIZE="$GASSIAN_FALLBACK_STEREO_RTABMAP_SYNC_QUEUE_SIZE"
  fi
fi

if [[ "$WAIT_FOR_CAMERA_READY" == "True" ]]; then
  wait_for_camera_inputs
fi

if [[ "$WAIT_FOR_ODOM_READY" == "True" ]]; then
  wait_for_odom_input
fi

if [[ "$START_ODOM_NAV2_BRIDGE" == "True" ]]; then
  start_odom_nav2_bridge
fi

if [[ "$DELETE_DB_ON_START" == "False" ]]; then
  RTABMAP_ARGS="$(remove_rtabmap_arg "$RTABMAP_ARGS" "--delete_db_on_start")"
  RTABMAP_ARGS="$(remove_rtabmap_arg "$RTABMAP_ARGS" "-d")"
fi

if [[ -n "$RTABMAP_DB_PATH" ]]; then
  mkdir -p "$(dirname "$RTABMAP_DB_PATH")"
fi

if [[ "$RGB_TOPIC" == */image_raw ]]; then
  RTABMAP_ARGS="$(ensure_rtabmap_param_arg "$RTABMAP_ARGS" "Rtabmap/ImagesAlreadyRectified" "false")"
fi

echo "Launching RTAB-Map RGB-D"
echo "  rgb_topic=$RGB_TOPIC"
echo "  camera_info_topic=$CAMERA_INFO_TOPIC"
echo "  depth_topic=$DEPTH_TOPIC"
echo "  odom_topic=$ODOM_TOPIC"
echo "  nav2_odom_topic=$NAV2_ODOM_TOPIC"
echo "  odom_frame_id=$ODOM_FRAME_ID"
echo "  frame_id=$FRAME_ID"
echo "  visual_odometry=$VISUAL_ODOMETRY"
echo "  qos=$QOS"
echo "  topic_queue_size=$TOPIC_QUEUE_SIZE"
echo "  sync_queue_size=$SYNC_QUEUE_SIZE"
echo "  approx_sync_max_interval=$APPROX_SYNC_MAX_INTERVAL"
echo "  wait_for_transform=$WAIT_FOR_TRANSFORM"
echo "  wait_for_odom_ready=$WAIT_FOR_ODOM_READY"
echo "  delete_db_on_start=$DELETE_DB_ON_START"
if [[ -n "$RTABMAP_DB_PATH" ]]; then
  echo "  database_path=$RTABMAP_DB_PATH"
fi
echo "  DDS_IFACE=$DDS_IFACE"

if [[ "$RGB_TOPIC" == */image_raw ]]; then
  echo "  raw_rgb_rectification=forcing Rtabmap/ImagesAlreadyRectified=false"
fi

if [[ "$DEPTH_TOPIC" == "$GASSIAN_ALT_DEPTH_TOPIC" ]]; then
  echo "  depth_selection=preferred aligned depth topic detected"
elif [[ "$DEPTH_TOPIC" == "$GASSIAN_DEFAULT_DEPTH_TOPIC" ]]; then
  echo "  depth_selection=fallback stereo depth topic"
  echo "  sync_tuning=applied fallback stereo sync defaults when not explicitly overridden"
fi

if [[ "$DEPTH_TOPIC" == "$GASSIAN_DEFAULT_DEPTH_TOPIC" && "$CAMERA_INFO_TOPIC" == "$GASSIAN_DEFAULT_CAMERA_INFO_TOPIC" ]]; then
  echo "WARNING: using stereo depth with RGB camera_info. Mapping will be unstable unless the OAK driver is publishing depth already aligned to RGB." >&2
  echo "         Prefer /oak/depth/image_raw when it exists, or validate the live timestamps/frame_ids with ./scripts/check_rtabmap_sync.sh before mapping." >&2
fi

echo "Cleaning up any previous RTAB-Map launch processes..."
pkill -f '/opt/ros/humble/lib/rtabmap_odom/' >/dev/null 2>&1 || true
pkill -f '/opt/ros/humble/lib/rtabmap_slam/rtabmap' >/dev/null 2>&1 || true
pkill -f 'rtabmap_launch' >/dev/null 2>&1 || true
sleep 2

launch_cmd=(
  ros2 launch rtabmap_launch rtabmap.launch.py
  "rtabmap_args:=$RTABMAP_ARGS"
  "frame_id:=$FRAME_ID"
  "rgb_topic:=$RGB_TOPIC"
  "depth_topic:=$DEPTH_TOPIC"
  "camera_info_topic:=$CAMERA_INFO_TOPIC"
  "odom_topic:=$ODOM_TOPIC"
  "map_topic:=/map"
  "vo_frame_id:=$ODOM_FRAME_ID"
  "odom_frame_id:=$ODOM_FRAME_ID"
  "visual_odometry:=$VISUAL_ODOMETRY"
  "rtabmap_viz:=$RTABMAP_VIZ"
  "rviz:=$RVIZ"
  "approx_sync:=$APPROX_SYNC"
  "approx_sync_max_interval:=$APPROX_SYNC_MAX_INTERVAL"
  "topic_queue_size:=$TOPIC_QUEUE_SIZE"
  "sync_queue_size:=$SYNC_QUEUE_SIZE"
  "wait_for_transform:=$WAIT_FOR_TRANSFORM"
  "qos:=$QOS"
)

if [[ -n "$RTABMAP_DB_PATH" ]]; then
  launch_cmd+=("database_path:=$RTABMAP_DB_PATH")
fi

exec "${launch_cmd[@]}"
