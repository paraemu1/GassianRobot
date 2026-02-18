#!/usr/bin/env bash
set -euo pipefail

# Launch OAK-D Pro using depthai_ros_driver.
# Run this inside the RTAB-Map container shell.

NAME="${NAME:-oak}"
NAMESPACE="${NAMESPACE:-}"
PARENT_FRAME="${PARENT_FRAME:-base_link}"
CAMERA_MODEL="${CAMERA_MODEL:-OAK-D-PRO}"
USE_RVIZ="${USE_RVIZ:-false}"
POINTCLOUD_ENABLE="${POINTCLOUD_ENABLE:-false}"
RECTIFY_RGB="${RECTIFY_RGB:-true}"

if ! command -v ros2 >/dev/null 2>&1; then
  echo "Missing required command: ros2" >&2
  exit 1
fi

launch_args=(
  "name:=$NAME"
  "parent_frame:=$PARENT_FRAME"
  "camera_model:=$CAMERA_MODEL"
  "use_rviz:=$USE_RVIZ"
  "pointcloud.enable:=$POINTCLOUD_ENABLE"
  "rectify_rgb:=$RECTIFY_RGB"
)

if [[ -n "$NAMESPACE" ]]; then
  launch_args+=("namespace:=$NAMESPACE")
fi

ros2 launch depthai_ros_driver camera.launch.py \
  "${launch_args[@]}"
