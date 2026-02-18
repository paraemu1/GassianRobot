#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-gassian/ros2-humble-rtabmap:latest}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-docker/rtabmap.Dockerfile}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker and retry." >&2
  exit 1
fi

if [[ ! -f "$DOCKERFILE_PATH" ]]; then
  echo "Dockerfile not found: $DOCKERFILE_PATH" >&2
  exit 1
fi

echo "Building image: $IMAGE_TAG"
docker build -f "$DOCKERFILE_PATH" -t "$IMAGE_TAG" .
echo "Build complete: $IMAGE_TAG"
