#!/usr/bin/env bash
set -euo pipefail

# Launch OAK-D Pro using depthai_ros_driver.
# Can run inside the robot runtime container directly, or from the host where it
# will exec into the running container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

NAME="${NAME:-oak}"
NAMESPACE="${NAMESPACE:-}"
PARENT_FRAME="${PARENT_FRAME:-base_link}"
CAMERA_MODEL="${CAMERA_MODEL:-OAK-D-PRO}"
USE_RVIZ="${USE_RVIZ:-false}"
POINTCLOUD_ENABLE="${POINTCLOUD_ENABLE:-false}"
RECTIFY_RGB="${RECTIFY_RGB:-true}"
PARAMS_FILE="${PARAMS_FILE:-${REPO_ROOT}/config/oak_rgbd_sync.yaml}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
PREFER_RUNNING_CONTAINER="${PREFER_RUNNING_CONTAINER:-$GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER}"

apply_autonomy_local_defaults

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

run_in_container() {
  local container_params_file
  container_params_file="$(containerize_params_file "$PARAMS_FILE")"

  require_cmd docker

  if ! docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    echo "Robot runtime container is not running: $ROS_CONTAINER" >&2
    echo "Start it first: ./scripts/run_robot_runtime_container.sh" >&2
    exit 1
  fi

  exec docker exec -i \
    -e IN_OAK_CAMERA_CONTAINER=1 \
    -e NAME="$NAME" \
    -e NAMESPACE="$NAMESPACE" \
    -e PARENT_FRAME="$PARENT_FRAME" \
    -e CAMERA_MODEL="$CAMERA_MODEL" \
    -e USE_RVIZ="$USE_RVIZ" \
    -e POINTCLOUD_ENABLE="$POINTCLOUD_ENABLE" \
    -e RECTIFY_RGB="$RECTIFY_RGB" \
    -e PARAMS_FILE="$container_params_file" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_CONTAINER" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/run_oak_camera.sh"
}

if [[ "${IN_OAK_CAMERA_CONTAINER:-0}" != "1" && "$PREFER_RUNNING_CONTAINER" == "1" ]] && ros_container_is_running "$ROS_CONTAINER"; then
  run_in_container
fi

if ! command -v ros2 >/dev/null 2>&1; then
  run_in_container
fi

require_cmd ros2

if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
  ensure_dds_iface_exists "$DDS_IFACE"
fi

echo "Launching OAK camera"
echo "  name=$NAME"
echo "  parent_frame=$PARENT_FRAME"
echo "  camera_model=$CAMERA_MODEL"
echo "  rectify_rgb=$RECTIFY_RGB"
echo "  pointcloud_enable=$POINTCLOUD_ENABLE"
echo "  params_file=$PARAMS_FILE"

echo "Cleaning up any previous OAK launch processes..."
pkill -f 'depthai_ros_driver camera.launch.py' >/dev/null 2>&1 || true
pkill -f 'component_container.*oak_container' >/dev/null 2>&1 || true
sleep 2

launch_args=(
  "name:=$NAME"
  "parent_frame:=$PARENT_FRAME"
  "camera_model:=$CAMERA_MODEL"
  "use_rviz:=$USE_RVIZ"
  "pointcloud.enable:=$POINTCLOUD_ENABLE"
  "rectify_rgb:=$RECTIFY_RGB"
)

if [[ -n "$PARAMS_FILE" ]]; then
  if [[ ! -f "$PARAMS_FILE" ]]; then
    echo "OAK params file not found: $PARAMS_FILE" >&2
    exit 1
  fi
  launch_args+=("params_file:=$PARAMS_FILE")
fi

if [[ -n "$NAMESPACE" ]]; then
  launch_args+=("namespace:=$NAMESPACE")
fi

ros2 launch depthai_ros_driver camera.launch.py \
  "${launch_args[@]}"
