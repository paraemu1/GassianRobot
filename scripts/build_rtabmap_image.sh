#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export IMAGE_TAG="${IMAGE_TAG:-gassian/robot-runtime:latest}"
export COMPAT_IMAGE_TAG="${COMPAT_IMAGE_TAG:-gassian/ros2-humble-rtabmap:latest}"

exec "${SCRIPT_DIR}/build_robot_runtime_image.sh" "$@"
