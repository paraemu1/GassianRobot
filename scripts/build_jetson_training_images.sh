#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRY_RUN=0
NO_CACHE=0
PULL=0
PROGRESS=""

usage() {
  cat <<'USAGE'
Build all Gaussian training Docker images.

Usage:
  ./scripts/build_jetson_training_images.sh [--dry-run] [--no-cache] [--pull] [--progress <auto|plain|tty>]

Options:
  --dry-run                Print docker build commands without running them.
  --no-cache               Build images without using cache.
  --pull                   Always attempt to pull newer base images.
  --progress <mode>        Docker build progress mode: auto, plain, tty.
  -h, --help               Show this help.
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

build_image() {
  local dockerfile="$1"
  local tag="$2"
  local -a cmd=(docker build)

  if [[ "$NO_CACHE" -eq 1 ]]; then
    cmd+=(--no-cache)
  fi
  if [[ "$PULL" -eq 1 ]]; then
    # Only pull for images whose base comes from a remote registry.
    # Downstream images in this chain depend on locally-built gassian/* tags.
    if [[ "$dockerfile" == "docker/gsplat_train.Dockerfile" ]]; then
      cmd+=(--pull)
    fi
  fi
  if [[ -n "$PROGRESS" ]]; then
    cmd+=("--progress=${PROGRESS}")
  fi

  cmd+=( -f "${REPO_ROOT}/${dockerfile}" -t "${tag}" "${REPO_ROOT}" )

  echo ""
  echo "=== Building ${tag} from ${dockerfile} ==="
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%q ' "${cmd[@]}"
    echo ""
  else
    "${cmd[@]}"
  fi
}

build_image "docker/gsplat_train.Dockerfile" "gassian/gsplat-train:latest"
build_image "docker/gsplat_train_colmap.Dockerfile" "gassian/gsplat-train:colmap"
build_image "docker/gsplat_train_cuda_colmap.Dockerfile" "gassian/gsplat-train:cuda-colmap"
build_image "docker/gsplat_train_jetson_compatible.Dockerfile" "gassian/gsplat-train:jetson-compatible"

echo ""
echo "All training images are built."
echo "Primary training image: gassian/gsplat-train:jetson-compatible"
