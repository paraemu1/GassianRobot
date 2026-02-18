#!/usr/bin/env bash
set -euo pipefail

# Default raw topics for Create 3 + RPLIDAR + OAK-D Pro.
DEPTH_TOPIC="${DEPTH_TOPIC:-/oak/depth/image_raw}"
TOPICS="${TOPICS:-/tf /tf_static /odom /scan /oak/rgb/image_raw /oak/rgb/camera_info}"
RUN_NAME="${RUN_NAME:-$(date +%F)-rtabmap_capture}"
OUT_DIR="${OUT_DIR:-runs/$RUN_NAME/raw}"

mkdir -p "$OUT_DIR"

if ! command -v ros2 >/dev/null 2>&1; then
  echo "Missing required command: ros2" >&2
  exit 1
fi

echo "Recording rosbag to: $OUT_DIR"
if [[ -n "$DEPTH_TOPIC" ]] && [[ "$TOPICS" != *"$DEPTH_TOPIC"* ]]; then
  TOPICS="$TOPICS $DEPTH_TOPIC"
fi
echo "Topics: $TOPICS"
echo "Press Ctrl+C to stop."

# MCAP storage keeps files compact and faster to index than sqlite by default.
ros2 bag record \
  --storage mcap \
  --output "$OUT_DIR/rosbag" \
  $TOPICS
