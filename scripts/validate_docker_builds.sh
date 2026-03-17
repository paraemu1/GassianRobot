#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="cached"
TARGET="training"
PROGRESS=""
DRY_RUN=0
TRAIN_IMAGE_TAGS=(
  "gassian/gsplat-train:latest"
  "gassian/gsplat-train:colmap"
  "gassian/gsplat-train:cuda-colmap"
  "gassian/gsplat-train:jetson-compatible"
)
RTABMAP_IMAGE_TAG="${IMAGE_TAG:-gassian/ros2-humble-rtabmap:latest}"

PASS_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<'USAGE'
Validate Docker builds for Gaussian training and RTAB-Map.

Usage:
  ./scripts/validate_docker_builds.sh [--mode cached|clean] [--target training|rtabmap|all]

Options:
  --mode <cached|clean>          Build mode. clean implies --no-cache --pull.
  --target <training|rtabmap|all>
                                 Which image groups to validate.
  --progress <auto|plain|tty>    Optional Docker build progress mode.
  --dry-run                      Print commands without executing.
  -h, --help                     Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --mode" >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --target" >&2
        exit 1
      fi
      TARGET="$2"
      shift 2
      ;;
    --progress)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --progress" >&2
        exit 1
      fi
      PROGRESS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "cached" && "$MODE" != "clean" ]]; then
  echo "Invalid --mode: $MODE" >&2
  exit 1
fi

if [[ "$TARGET" != "training" && "$TARGET" != "rtabmap" && "$TARGET" != "all" ]]; then
  echo "Invalid --target: $TARGET" >&2
  exit 1
fi

if [[ -n "$PROGRESS" && "$PROGRESS" != "auto" && "$PROGRESS" != "plain" && "$PROGRESS" != "tty" ]]; then
  echo "Invalid --progress value: $PROGRESS" >&2
  echo "Allowed values: auto, plain, tty" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: docker" >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi
fi

docker_supports_progress_flag() {
  docker build --help 2>/dev/null | grep -q -- '--progress'
}

if [[ -n "$PROGRESS" && "$DRY_RUN" -eq 0 ]]; then
  if ! docker_supports_progress_flag; then
    echo "This Docker builder does not support --progress. Omit --progress or enable BuildKit/buildx." >&2
    exit 1
  fi
fi

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: '
    printf '%q ' "$@"
    echo ""
    return 0
  fi
  "$@"
}

record_pass() {
  local message="$1"
  echo "[PASS] ${message}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

record_fail() {
  local message="$1"
  echo "[FAIL] ${message}" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

build_training_images() {
  local -a build_args=()

  if [[ "$MODE" == "clean" ]]; then
    build_args+=(--no-cache --pull)
  fi

  if [[ -n "$PROGRESS" ]]; then
    build_args+=(--progress "$PROGRESS")
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    build_args+=(--dry-run)
  fi

  if run_cmd "${SCRIPT_DIR}/build_jetson_training_images.sh" "${build_args[@]}"; then
    record_pass "training image build chain (${MODE})"
    return 0
  fi

  record_fail "training image build chain (${MODE})"
  return 1
}

verify_training_image() {
  local image_tag="$1"
  local cmd=(
    docker run --rm --network host --ipc host
    "$image_tag"
    bash -lc
    "python3 -m pip show nerfstudio >/dev/null && python3 -m pip show gsplat >/dev/null && colmap -h >/dev/null && ns-train --help >/dev/null"
  )

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! docker image inspect "$image_tag" >/dev/null 2>&1; then
      record_fail "training image missing locally: ${image_tag}"
      return 1
    fi
  fi

  if run_cmd "${cmd[@]}"; then
    record_pass "training image verification: ${image_tag}"
    return 0
  fi

  record_fail "training image verification: ${image_tag}"
  return 1
}

build_rtabmap_image() {
  local -a cmd=(docker build)

  if [[ "$MODE" == "clean" ]]; then
    cmd+=(--no-cache --pull)
  fi

  if [[ -n "$PROGRESS" ]]; then
    cmd+=("--progress=${PROGRESS}")
  fi

  cmd+=( -f "${REPO_ROOT}/docker/rtabmap.Dockerfile" -t "$RTABMAP_IMAGE_TAG" "$REPO_ROOT" )

  if run_cmd "${cmd[@]}"; then
    record_pass "rtabmap image build (${MODE})"
    return 0
  fi

  record_fail "rtabmap image build (${MODE})"
  return 1
}

verify_rtabmap_image() {
  local -a cmd=(
    docker run --rm --network host
    "$RTABMAP_IMAGE_TAG"
    bash -lc
    "source /opt/ros/humble/setup.bash && ros2 pkg list | grep -Fxq rtabmap_ros"
  )

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! docker image inspect "$RTABMAP_IMAGE_TAG" >/dev/null 2>&1; then
      record_fail "rtabmap image missing locally: ${RTABMAP_IMAGE_TAG}"
      return 1
    fi
  fi

  if run_cmd "${cmd[@]}"; then
    record_pass "rtabmap image verification: ${RTABMAP_IMAGE_TAG}"
    return 0
  fi

  record_fail "rtabmap image verification: ${RTABMAP_IMAGE_TAG}"
  return 1
}

run_training_flow() {
  local build_ok=0
  if build_training_images; then
    build_ok=1
  fi

  if [[ "$build_ok" -eq 1 ]]; then
    local tag
    for tag in "${TRAIN_IMAGE_TAGS[@]}"; do
      verify_training_image "$tag" || true
    done
  else
    local tag
    for tag in "${TRAIN_IMAGE_TAGS[@]}"; do
      record_fail "training image verification skipped due build failure: ${tag}"
    done
  fi
}

run_rtabmap_flow() {
  local build_ok=0
  if build_rtabmap_image; then
    build_ok=1
  fi

  if [[ "$build_ok" -eq 1 ]]; then
    verify_rtabmap_image || true
  else
    record_fail "rtabmap image verification skipped due build failure"
  fi
}

if [[ "$TARGET" == "training" || "$TARGET" == "all" ]]; then
  run_training_flow
fi

if [[ "$TARGET" == "rtabmap" || "$TARGET" == "all" ]]; then
  run_rtabmap_flow
fi

echo ""
echo "Validation summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
