#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-gassian/ros2-humble-rtabmap:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-ros_humble_rtabmap}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/robot_ws}"

mkdir -p "$WORKSPACE_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker and retry." >&2
  exit 1
fi

# Remove an exited/old container with the same name to keep launch idempotent.
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

docker run --rm -it \
  --name "$CONTAINER_NAME" \
  --network host \
  --ipc host \
  --privileged \
  -v "$WORKSPACE_DIR:/robot_ws" \
  -w /robot_ws \
  --device /dev/bus/usb:/dev/bus/usb \
  "$IMAGE_TAG" \
  bash -lc "source /opt/ros/humble/setup.bash && exec bash"
