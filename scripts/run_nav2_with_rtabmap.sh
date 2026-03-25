#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

# Launch Nav2 navigation stack while localization/map come from RTAB-Map.
# Expected: RTAB-Map is already publishing map->odom TF and /map.

NAMESPACE="${NAMESPACE:-}"
USE_SIM_TIME="${USE_SIM_TIME:-false}"
AUTOSTART="${AUTOSTART:-true}"
PARAMS_FILE="${PARAMS_FILE:-${REPO_ROOT}/config/nav2_rtabmap_params.yaml}"
USE_COMPOSITION="${USE_COMPOSITION:-false}"
USE_RESPAWN="${USE_RESPAWN:-false}"
LOG_LEVEL="${LOG_LEVEL:-info}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
PREFER_RUNNING_CONTAINER="${PREFER_RUNNING_CONTAINER:-$GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER}"
WAIT_FOR_RTABMAP_READY="${WAIT_FOR_RTABMAP_READY:-true}"
RTABMAP_READY_TIMEOUT_SEC="${RTABMAP_READY_TIMEOUT_SEC:-45}"
RTABMAP_READY_RETRY_SEC="${RTABMAP_READY_RETRY_SEC:-3}"
RTABMAP_READY_DURATION_SEC="${RTABMAP_READY_DURATION_SEC:-4}"
RTABMAP_READY_MIN_RGB_SAMPLES="${RTABMAP_READY_MIN_RGB_SAMPLES:-4}"
ODOM_FRAME_ID="${ODOM_FRAME_ID:-odom}"
FRAME_ID="${FRAME_ID:-$GASSIAN_DEFAULT_RTABMAP_FRAME_ID}"
MAP_FRAME="${MAP_FRAME:-map}"

apply_autonomy_local_defaults

ODOM_FRAME_ID="$(normalize_frame_id "$ODOM_FRAME_ID")"
FRAME_ID="$(normalize_frame_id "$FRAME_ID")"
MAP_FRAME="$(normalize_frame_id "$MAP_FRAME")"

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

containerize_params_file() {
  local path="$1"

  if [[ "$path" == "$REPO_ROOT/"* ]]; then
    printf "%s/%s" "$CONTAINER_WORKDIR" "${path#$REPO_ROOT/}"
    return 0
  fi

  printf "%s" "$path"
}

USE_SIM_TIME="$(normalize_bool "$USE_SIM_TIME")"
AUTOSTART="$(normalize_bool "$AUTOSTART")"
USE_COMPOSITION="$(normalize_bool "$USE_COMPOSITION")"
USE_RESPAWN="$(normalize_bool "$USE_RESPAWN")"
WAIT_FOR_RTABMAP_READY="$(normalize_bool "$WAIT_FOR_RTABMAP_READY")"

wait_for_rtabmap_ready() {
  local deadline=$((SECONDS + RTABMAP_READY_TIMEOUT_SEC))
  local attempt=1
  local ready_log="/tmp/run_nav2_with_rtabmap.ready.$$"

  rm -f "$ready_log"
  echo "Waiting for RTAB-Map readiness before launching Nav2..."

  while (( SECONDS < deadline )); do
    if CHECK_MAP_ODOM_TF=1 \
      CHECK_TF_READY=1 \
      DURATION_SEC="$RTABMAP_READY_DURATION_SEC" \
      MIN_RGB_SAMPLES="$RTABMAP_READY_MIN_RGB_SAMPLES" \
      ODOM_FRAME_ID="$ODOM_FRAME_ID" \
      FRAME_ID="$FRAME_ID" \
      MAP_FRAME="$MAP_FRAME" \
      PREFER_RUNNING_CONTAINER=0 \
      REQUIRE_DDS_IFACE=0 \
      "${SCRIPT_DIR}/check_rtabmap_sync.sh" >"$ready_log" 2>&1; then
      cat "$ready_log"
      rm -f "$ready_log"
      return 0
    fi

    echo "RTAB-Map not ready yet (attempt ${attempt})." >&2
    sed -n '1,120p' "$ready_log" >&2 || true
    attempt=$((attempt + 1))
    sleep "$RTABMAP_READY_RETRY_SEC"
  done

  echo "Timed out waiting for RTAB-Map readiness." >&2
  sed -n '1,160p' "$ready_log" >&2 || true
  rm -f "$ready_log"
  return 1
}

launch_args=(
  "use_sim_time:=$USE_SIM_TIME"
  "params_file:=$PARAMS_FILE"
  "autostart:=$AUTOSTART"
  "use_composition:=$USE_COMPOSITION"
  "use_respawn:=$USE_RESPAWN"
  "log_level:=$LOG_LEVEL"
)

if [[ -n "$NAMESPACE" ]]; then
  launch_args+=("namespace:=$NAMESPACE")
fi

run_in_container() {
  local container_params_file
  container_params_file="$(containerize_params_file "$PARAMS_FILE")"

  require_cmd docker

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi

  if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
    ensure_dds_iface_exists "$DDS_IFACE"
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    exec docker exec -i \
      -e IN_NAV2_RTABMAP_CONTAINER=1 \
      -e NAMESPACE="$NAMESPACE" \
      -e USE_SIM_TIME="$USE_SIM_TIME" \
      -e AUTOSTART="$AUTOSTART" \
      -e PARAMS_FILE="$container_params_file" \
      -e USE_COMPOSITION="$USE_COMPOSITION" \
      -e USE_RESPAWN="$USE_RESPAWN" \
      -e LOG_LEVEL="$LOG_LEVEL" \
      -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
      -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
      -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
      -e WAIT_FOR_RTABMAP_READY="$WAIT_FOR_RTABMAP_READY" \
      -e RTABMAP_READY_TIMEOUT_SEC="$RTABMAP_READY_TIMEOUT_SEC" \
      -e RTABMAP_READY_RETRY_SEC="$RTABMAP_READY_RETRY_SEC" \
      -e RTABMAP_READY_DURATION_SEC="$RTABMAP_READY_DURATION_SEC" \
      -e RTABMAP_READY_MIN_RGB_SAMPLES="$RTABMAP_READY_MIN_RGB_SAMPLES" \
      -e ODOM_FRAME_ID="$ODOM_FRAME_ID" \
      -e FRAME_ID="$FRAME_ID" \
      -e MAP_FRAME="$MAP_FRAME" \
      "$ROS_CONTAINER" \
      bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/run_nav2_with_rtabmap.sh"
  fi

  if ! docker image inspect "$ROS_IMAGE" >/dev/null 2>&1; then
    echo "Docker image not found: $ROS_IMAGE" >&2
    echo "Build it first: ./scripts/build_robot_runtime_image.sh" >&2
    exit 1
  fi

  docker_run_args=(
    --rm
    --network host
    --ipc host
    -v "${REPO_ROOT}:${CONTAINER_WORKDIR}:ro"
    -e IN_NAV2_RTABMAP_CONTAINER=1
    -e ROS_IMAGE="$ROS_IMAGE"
    -e ROS_CONTAINER="$ROS_CONTAINER"
    -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION"
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID"
    -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY"
    -e DDS_IFACE="$DDS_IFACE"
    -e DDS_INCLUDE_LOOPBACK="$DDS_INCLUDE_LOOPBACK"
    -e CYCLONEDDS_URI="$CYCLONEDDS_URI"
    -e NAMESPACE="$NAMESPACE"
    -e USE_SIM_TIME="$USE_SIM_TIME"
    -e AUTOSTART="$AUTOSTART"
    -e PARAMS_FILE="$container_params_file"
    -e USE_COMPOSITION="$USE_COMPOSITION"
    -e USE_RESPAWN="$USE_RESPAWN"
    -e LOG_LEVEL="$LOG_LEVEL"
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR"
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE"
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER"
    -e WAIT_FOR_RTABMAP_READY="$WAIT_FOR_RTABMAP_READY"
    -e RTABMAP_READY_TIMEOUT_SEC="$RTABMAP_READY_TIMEOUT_SEC"
    -e RTABMAP_READY_RETRY_SEC="$RTABMAP_READY_RETRY_SEC"
    -e RTABMAP_READY_DURATION_SEC="$RTABMAP_READY_DURATION_SEC"
    -e RTABMAP_READY_MIN_RGB_SAMPLES="$RTABMAP_READY_MIN_RGB_SAMPLES"
    -e ODOM_FRAME_ID="$ODOM_FRAME_ID"
    -e FRAME_ID="$FRAME_ID"
    -e MAP_FRAME="$MAP_FRAME"
  )

  if [[ -t 0 && -t 1 ]]; then
    exec docker run -it \
      "${docker_run_args[@]}" \
      "$ROS_IMAGE" \
      bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/run_nav2_with_rtabmap.sh"
  fi

  exec docker run \
    "${docker_run_args[@]}" \
    "$ROS_IMAGE" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/run_nav2_with_rtabmap.sh"
}

if [[ "${IN_NAV2_RTABMAP_CONTAINER:-0}" != "1" && "$PREFER_RUNNING_CONTAINER" == "1" ]] && ros_container_is_running "$ROS_CONTAINER"; then
  run_in_container
fi

if ! command -v ros2 >/dev/null 2>&1 && [[ "${IN_NAV2_RTABMAP_CONTAINER:-0}" != "1" ]]; then
  run_in_container
fi

require_cmd ros2

if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
  ensure_dds_iface_exists "$DDS_IFACE"
fi

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "Nav2 params file not found: $PARAMS_FILE" >&2
  exit 1
fi

if [[ "$WAIT_FOR_RTABMAP_READY" == "True" ]]; then
  wait_for_rtabmap_ready
fi

exec ros2 launch nav2_bringup navigation_launch.py "${launch_args[@]}"
