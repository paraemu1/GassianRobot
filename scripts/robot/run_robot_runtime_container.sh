#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

CREATE3_DIRECT_DDS="${CREATE3_DIRECT_DDS:-0}"

export IMAGE_TAG="${IMAGE_TAG:-gassian/robot-runtime:latest}"
export CONTAINER_NAME="${CONTAINER_NAME:-ros_humble_robot_runtime}"
export ROS_IMAGE="${ROS_IMAGE:-$IMAGE_TAG}"
export ROS_CONTAINER="${ROS_CONTAINER:-$CONTAINER_NAME}"

if [[ "$CREATE3_DIRECT_DDS" == "1" ]]; then
  echo "Runtime container mode: direct Create 3 DDS"
else
  echo "Runtime container mode: autonomy-local DDS"
  apply_autonomy_local_defaults
fi

exec "${SCRIPT_DIR}/run_rtabmap_container.sh" "$@"
