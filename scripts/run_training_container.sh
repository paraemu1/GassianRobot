#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-gassian/gsplat-train:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-gsplat_train}"
RUNS_DIR="${RUNS_DIR:-$PWD/runs}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/robot_ws}"

mkdir -p "$RUNS_DIR" "$WORKSPACE_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker and retry." >&2
  exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

docker run --rm -it \
  --name "$CONTAINER_NAME" \
  --network host \
  --ipc host \
  --runtime nvidia \
  -v "$RUNS_DIR:/workspace/runs" \
  -v "$WORKSPACE_DIR:/workspace/robot_ws" \
  -w /workspace \
  "$IMAGE_TAG" \
  bash
