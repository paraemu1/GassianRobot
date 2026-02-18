#!/usr/bin/env bash
set -euo pipefail

RGB_TOPIC="${RGB_TOPIC:-/oak/rgb/image_raw}"
CAMERA_INFO_TOPIC="${CAMERA_INFO_TOPIC:-/oak/rgb/camera_info}"
DEPTH_TOPIC="${DEPTH_TOPIC:-/oak/stereo/image_raw}"
ODOM_TOPIC="${ODOM_TOPIC:-/odom}"
FRAME_ID="${FRAME_ID:-base_link}"
RTABMAP_VIZ="${RTABMAP_VIZ:-false}"
RVIZ="${RVIZ:-false}"

if ! command -v ros2 >/dev/null 2>&1; then
  echo "Missing required command: ros2" >&2
  exit 1
fi

ros2 launch rtabmap_launch rtabmap.launch.py \
  rtabmap_args:="--delete_db_on_start" \
  frame_id:="$FRAME_ID" \
  rgb_topic:="$RGB_TOPIC" \
  depth_topic:="$DEPTH_TOPIC" \
  camera_info_topic:="$CAMERA_INFO_TOPIC" \
  odom_topic:="$ODOM_TOPIC" \
  rtabmap_viz:="$RTABMAP_VIZ" \
  rviz:="$RVIZ" \
  approx_sync:=true \
  qos:=1
