#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Start Docker and retry." >&2
  exit 1
fi

build_image() {
  local dockerfile="$1"
  local tag="$2"
  echo ""
  echo "=== Building ${tag} from ${dockerfile} ==="
  docker build -f "${REPO_ROOT}/${dockerfile}" -t "${tag}" "${REPO_ROOT}"
}

build_image "docker/gsplat_train.Dockerfile" "gassian/gsplat-train:latest"
build_image "docker/gsplat_train_colmap.Dockerfile" "gassian/gsplat-train:colmap"
build_image "docker/gsplat_train_cuda_colmap.Dockerfile" "gassian/gsplat-train:cuda-colmap"
build_image "docker/gsplat_train_jetson_compatible.Dockerfile" "gassian/gsplat-train:jetson-compatible"

echo ""
echo "All training images are built."
echo "Primary training image: gassian/gsplat-train:jetson-compatible"
