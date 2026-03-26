#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

IMAGE_TAG="${IMAGE_TAG:-${ROS_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}}"
CONTAINER_NAME="${CONTAINER_NAME:-${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_ROOT}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
CREATE3_DIRECT_DDS="${CREATE3_DIRECT_DDS:-0}"

export ROS_IMAGE="$IMAGE_TAG"
export ROS_CONTAINER="$CONTAINER_NAME"
if [[ "$CREATE3_DIRECT_DDS" == "1" ]]; then
  apply_create3_oak_defaults
else
  apply_autonomy_local_defaults
fi

mkdir -p "$WORKSPACE_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker and retry." >&2
  exit 1
fi

if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
  ensure_dds_iface_exists "$DDS_IFACE"
fi

# Remove an exited/old container with the same name to keep launch idempotent.
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Starting robot runtime container: $CONTAINER_NAME"
echo "Repo mount: $WORKSPACE_DIR -> $CONTAINER_WORKDIR"
echo "ROS env: RMW=$RMW_IMPLEMENTATION DOMAIN=$ROS_DOMAIN_ID LOCALHOST_ONLY=$ROS_LOCALHOST_ONLY DDS_IFACE=$DDS_IFACE"

docker_run_args=(
  --rm
  --name "$CONTAINER_NAME"
  --network host
  --ipc host
  --privileged
  -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION"
  -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID"
  -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY"
  -e DDS_IFACE="$DDS_IFACE"
  -e DDS_INCLUDE_LOOPBACK="$DDS_INCLUDE_LOOPBACK"
  -e CYCLONEDDS_URI="$CYCLONEDDS_URI"
  -v "$WORKSPACE_DIR:$CONTAINER_WORKDIR"
  -w "$CONTAINER_WORKDIR"
  -v /dev:/dev
  -v /run/udev:/run/udev:ro
)

if [[ -t 0 && -t 1 ]]; then
  exec docker run -it \
    "${docker_run_args[@]}" \
    "$IMAGE_TAG" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec bash"
fi

echo "No TTY detected; starting robot runtime container detached."
exec docker run -d \
  "${docker_run_args[@]}" \
  "$IMAGE_TAG" \
  bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec sleep infinity"
