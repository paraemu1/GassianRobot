#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-gassian/robot-runtime:latest}"
COMPAT_IMAGE_TAG="${COMPAT_IMAGE_TAG:-gassian/ros2-humble-rtabmap:latest}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-docker/robot_runtime.Dockerfile}"
DRY_RUN=0
NO_CACHE=0
PULL=0
PROGRESS=""

usage() {
  cat <<'USAGE'
Build the robot runtime Docker image used for camera, control, mapping, and navigation.

Usage:
  ./scripts/build/build_robot_runtime_image.sh [--dry-run] [--no-cache] [--pull] [--progress <auto|plain|tty>]

Options:
  --dry-run                Print the docker build command without running it.
  --no-cache               Build without using cache.
  --pull                   Always attempt to pull newer base images.
  --progress <mode>        Docker build progress mode: auto, plain, tty.
  -h, --help               Show this help.

Environment overrides:
  IMAGE_TAG                Primary image tag. Default: gassian/robot-runtime:latest
  COMPAT_IMAGE_TAG         Optional extra tag for backward compatibility.
                           Default: gassian/ros2-humble-rtabmap:latest
  DOCKERFILE_PATH          Dockerfile path relative to repo root unless absolute.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift 1
      ;;
    --no-cache)
      NO_CACHE=1
      shift 1
      ;;
    --pull)
      PULL=1
      shift 1
      ;;
    --progress)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --progress" >&2
        exit 1
      fi
      PROGRESS="$2"
      shift 2
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

if [[ -n "$PROGRESS" && "$PROGRESS" != "auto" && "$PROGRESS" != "plain" && "$PROGRESS" != "tty" ]]; then
  echo "Invalid --progress value: $PROGRESS" >&2
  echo "Allowed values: auto, plain, tty" >&2
  exit 1
fi

if [[ "$DOCKERFILE_PATH" = /* ]]; then
  DOCKERFILE_ABS="$DOCKERFILE_PATH"
else
  DOCKERFILE_ABS="${REPO_ROOT}/${DOCKERFILE_PATH}"
fi

if [[ ! -f "$DOCKERFILE_ABS" ]]; then
  echo "Dockerfile not found: $DOCKERFILE_PATH" >&2
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

if [[ -n "$PROGRESS" && "$DRY_RUN" -eq 0 ]]; then
  if ! docker build --help 2>/dev/null | grep -q -- '--progress'; then
    echo "This Docker builder does not support --progress. Omit --progress or enable BuildKit/buildx." >&2
    exit 1
  fi
fi

cmd=(docker build)

if [[ "$NO_CACHE" -eq 1 ]]; then
  cmd+=(--no-cache)
fi
if [[ "$PULL" -eq 1 ]]; then
  cmd+=(--pull)
fi
if [[ -n "$PROGRESS" ]]; then
  cmd+=("--progress=${PROGRESS}")
fi

cmd+=(-f "$DOCKERFILE_ABS" -t "$IMAGE_TAG")
if [[ -n "$COMPAT_IMAGE_TAG" && "$COMPAT_IMAGE_TAG" != "$IMAGE_TAG" ]]; then
  cmd+=(-t "$COMPAT_IMAGE_TAG")
fi
cmd+=("$REPO_ROOT")

echo "Building robot runtime image"
echo "  dockerfile: $DOCKERFILE_PATH"
echo "  primary tag: $IMAGE_TAG"
if [[ -n "$COMPAT_IMAGE_TAG" && "$COMPAT_IMAGE_TAG" != "$IMAGE_TAG" ]]; then
  echo "  compatibility tag: $COMPAT_IMAGE_TAG"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%q ' "${cmd[@]}"
  echo ""
  exit 0
fi

"${cmd[@]}"

echo "Build complete."
echo "Primary runtime image: $IMAGE_TAG"
if [[ -n "$COMPAT_IMAGE_TAG" && "$COMPAT_IMAGE_TAG" != "$IMAGE_TAG" ]]; then
  echo "Compatibility tag also updated: $COMPAT_IMAGE_TAG"
fi
