#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

# Quick headless ROS 2 health checks for Create 3 + LiDAR + OAK.
# Override defaults with env vars, e.g. RGB_TOPIC=/camera/image_raw ./scripts/ros_health_check.sh

TF_TOPIC="${TF_TOPIC:-${TOPIC_TF:-$GASSIAN_DEFAULT_TF_TOPIC}}"
ODOM_TOPIC="${ODOM_TOPIC:-${TOPIC_ODOM:-$GASSIAN_DEFAULT_ODOM_TOPIC}}"
SCAN_TOPIC="${SCAN_TOPIC:-${TOPIC_SCAN:-$GASSIAN_DEFAULT_SCAN_TOPIC}}"
CAMERA_INFO_TOPIC="${CAMERA_INFO_TOPIC:-${TOPIC_CAMERA_INFO:-$GASSIAN_DEFAULT_CAMERA_INFO_TOPIC}}"
RGB_TOPIC="${RGB_TOPIC:-${TOPIC_IMAGE:-$GASSIAN_DEFAULT_RGB_TOPIC}}"
DEPTH_TOPIC="${DEPTH_TOPIC:-${TOPIC_DEPTH:-}}"
DEPTH_CAMERA_INFO_TOPIC="${DEPTH_CAMERA_INFO_TOPIC:-}"
TIMEOUT_SEC="${TIMEOUT_SEC:-8}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
REQUIRE_ODOM_TOPIC="${REQUIRE_ODOM_TOPIC:-1}"
REQUIRE_SCAN_TOPIC="${REQUIRE_SCAN_TOPIC:-0}"
PREFER_RUNNING_CONTAINER="${PREFER_RUNNING_CONTAINER:-$GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER}"

pass_count=0
fail_count=0

apply_autonomy_local_defaults

log() { printf "%s\n" "$*"; }
pass() { log "[PASS] $*"; pass_count=$((pass_count + 1)); }
fail() { log "[FAIL] $*"; fail_count=$((fail_count + 1)); }
warn() { log "[WARN] $*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

topic_exists() {
  local topic="$1"
  local topics
  topics="$(ros2 topic list 2>/dev/null || true)"
  printf '%s\n' "$topics" | grep -Fxq "$topic"
}

select_depth_topic() {
  if [[ -n "$DEPTH_TOPIC" ]]; then
    printf "%s" "$DEPTH_TOPIC"
    return 0
  fi

  if topic_exists "$GASSIAN_ALT_DEPTH_TOPIC"; then
    printf "%s" "$GASSIAN_ALT_DEPTH_TOPIC"
    return 0
  fi

  if topic_exists "$GASSIAN_DEFAULT_DEPTH_TOPIC"; then
    printf "%s" "$GASSIAN_DEFAULT_DEPTH_TOPIC"
    return 0
  fi

  printf "%s" "$GASSIAN_DEFAULT_DEPTH_TOPIC"
}

run_in_container() {
  require_cmd docker

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi

  if ! docker image inspect "$ROS_IMAGE" >/dev/null 2>&1; then
    echo "Docker image not found: $ROS_IMAGE" >&2
    echo "Build it first: ./scripts/build_robot_runtime_image.sh" >&2
    exit 1
  fi

  if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
    ensure_dds_iface_exists "$DDS_IFACE"
  fi

  if ros_container_is_running "$ROS_CONTAINER"; then
    exec docker exec -i \
      -e IN_ROS_HEALTH_CONTAINER=1 \
      -e TF_TOPIC="$TF_TOPIC" \
      -e ODOM_TOPIC="$ODOM_TOPIC" \
      -e SCAN_TOPIC="$SCAN_TOPIC" \
      -e CAMERA_INFO_TOPIC="$CAMERA_INFO_TOPIC" \
      -e RGB_TOPIC="$RGB_TOPIC" \
      -e DEPTH_TOPIC="$DEPTH_TOPIC" \
      -e DEPTH_CAMERA_INFO_TOPIC="$DEPTH_CAMERA_INFO_TOPIC" \
      -e TIMEOUT_SEC="$TIMEOUT_SEC" \
      -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
      -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
      -e REQUIRE_ODOM_TOPIC="$REQUIRE_ODOM_TOPIC" \
      -e REQUIRE_SCAN_TOPIC="$REQUIRE_SCAN_TOPIC" \
      -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
      "$ROS_CONTAINER" \
      bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/ros_health_check.sh"
  fi

  exec docker run --rm --network host \
    -v "${REPO_ROOT}:${CONTAINER_WORKDIR}:ro" \
    -e IN_ROS_HEALTH_CONTAINER=1 \
    -e ROS_IMAGE="$ROS_IMAGE" \
    -e ROS_CONTAINER="$ROS_CONTAINER" \
    -e RMW_IMPLEMENTATION="$RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROS_LOCALHOST_ONLY" \
    -e DDS_IFACE="$DDS_IFACE" \
    -e DDS_INCLUDE_LOOPBACK="$DDS_INCLUDE_LOOPBACK" \
    -e CYCLONEDDS_URI="$CYCLONEDDS_URI" \
    -e TF_TOPIC="$TF_TOPIC" \
    -e ODOM_TOPIC="$ODOM_TOPIC" \
    -e SCAN_TOPIC="$SCAN_TOPIC" \
    -e CAMERA_INFO_TOPIC="$CAMERA_INFO_TOPIC" \
    -e RGB_TOPIC="$RGB_TOPIC" \
    -e DEPTH_TOPIC="$DEPTH_TOPIC" \
    -e DEPTH_CAMERA_INFO_TOPIC="$DEPTH_CAMERA_INFO_TOPIC" \
    -e TIMEOUT_SEC="$TIMEOUT_SEC" \
    -e CONTAINER_WORKDIR="$CONTAINER_WORKDIR" \
    -e REQUIRE_DDS_IFACE="$REQUIRE_DDS_IFACE" \
    -e REQUIRE_ODOM_TOPIC="$REQUIRE_ODOM_TOPIC" \
    -e REQUIRE_SCAN_TOPIC="$REQUIRE_SCAN_TOPIC" \
    -e PREFER_RUNNING_CONTAINER="$PREFER_RUNNING_CONTAINER" \
    "$ROS_IMAGE" \
    bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec ./scripts/ros_health_check.sh"
}

if [[ "$CAMERA_INFO_TOPIC" == "$GASSIAN_DEFAULT_CAMERA_INFO_TOPIC" && "$RGB_TOPIC" != "$GASSIAN_DEFAULT_RGB_TOPIC" ]]; then
  CAMERA_INFO_TOPIC="$(resolve_rgb_camera_info_topic "$RGB_TOPIC")"
fi

if [[ "${IN_ROS_HEALTH_CONTAINER:-0}" != "1" && "$PREFER_RUNNING_CONTAINER" == "1" ]] && ros_container_is_running "$ROS_CONTAINER"; then
  run_in_container
fi

if ! command -v ros2 >/dev/null 2>&1 && [[ "${IN_ROS_HEALTH_CONTAINER:-0}" != "1" ]]; then
  run_in_container
fi

DEPTH_TOPIC="$(select_depth_topic)"

if [[ -z "$DEPTH_CAMERA_INFO_TOPIC" ]]; then
  if derived_depth_camera_info="$(derive_camera_info_topic_from_image_topic "$DEPTH_TOPIC" 2>/dev/null)"; then
    DEPTH_CAMERA_INFO_TOPIC="$derived_depth_camera_info"
  fi
fi

check_topic_exists() {
  local topic="$1"
  if topic_exists "$topic"; then
    pass "topic exists: $topic"
  else
    fail "topic missing: $topic"
  fi
}

check_echo_once() {
  local topic="$1"
  if timeout "$TIMEOUT_SEC" ros2 topic echo --once "$topic" >/dev/null 2>&1; then
    pass "echo once ok: $topic"
  else
    fail "echo once failed/timed out: $topic"
  fi
}

check_hz() {
  local topic="$1"
  local hz_out
  if ! topic_exists "$topic"; then
    fail "cannot measure hz, missing topic: $topic"
    return
  fi

  set +e
  hz_out="$(timeout "$TIMEOUT_SEC" ros2 topic hz "$topic" 2>&1)"
  set -e

  if printf "%s" "$hz_out" | grep -q "average rate:"; then
    pass "rate measured on $topic"
    printf "       %s\n" "$(printf "%s" "$hz_out" | grep "average rate:" | tail -n1)"
  else
    fail "no stable rate observed for $topic within ${TIMEOUT_SEC}s"
  fi
}

main() {
  require_cmd ros2
  require_cmd timeout

  if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
    ensure_dds_iface_exists "$DDS_IFACE"
  fi

  log "ROS health check starting..."
  log "ROS env:"
  log "  RMW:         $RMW_IMPLEMENTATION"
  log "  DOMAIN:      $ROS_DOMAIN_ID"
  log "  LOCALHOST:   $ROS_LOCALHOST_ONLY"
  log "  DDS_IFACE:   $DDS_IFACE"
  log "  REQUIRE_ODOM:$REQUIRE_ODOM_TOPIC"
  log "  REQUIRE_SCAN:$REQUIRE_SCAN_TOPIC"
  log ""
  log "Topics:"
  log "  TF:          $TF_TOPIC"
  log "  ODOM:        $ODOM_TOPIC"
  log "  SCAN:        $SCAN_TOPIC"
  log "  CAMERA_INFO: $CAMERA_INFO_TOPIC"
  log "  IMAGE:       $RGB_TOPIC"
  log "  DEPTH:       $DEPTH_TOPIC"
  if [[ -n "$DEPTH_CAMERA_INFO_TOPIC" ]]; then
    log "  DEPTH_INFO:  $DEPTH_CAMERA_INFO_TOPIC"
  fi
  log ""

  check_topic_exists "$TF_TOPIC"
  if [[ "$REQUIRE_ODOM_TOPIC" == "1" ]]; then
    check_topic_exists "$ODOM_TOPIC"
  elif topic_exists "$ODOM_TOPIC"; then
    pass "optional topic exists: $ODOM_TOPIC"
  else
    warn "optional topic missing: $ODOM_TOPIC"
  fi
  if [[ "$REQUIRE_SCAN_TOPIC" == "1" ]]; then
    check_topic_exists "$SCAN_TOPIC"
  elif topic_exists "$SCAN_TOPIC"; then
    pass "optional topic exists: $SCAN_TOPIC"
  else
    warn "optional topic missing: $SCAN_TOPIC"
  fi
  check_topic_exists "$CAMERA_INFO_TOPIC"
  check_topic_exists "$RGB_TOPIC"
  check_topic_exists "$DEPTH_TOPIC"
  if [[ -n "$DEPTH_CAMERA_INFO_TOPIC" ]]; then
    check_topic_exists "$DEPTH_CAMERA_INFO_TOPIC"
  fi

  check_echo_once "$TF_TOPIC"
  if topic_exists "$ODOM_TOPIC"; then
    check_echo_once "$ODOM_TOPIC"
  else
    warn "skipping echo once, missing optional topic: $ODOM_TOPIC"
  fi
  if topic_exists "$SCAN_TOPIC"; then
    check_echo_once "$SCAN_TOPIC"
  else
    warn "skipping echo once, missing optional topic: $SCAN_TOPIC"
  fi
  check_echo_once "$CAMERA_INFO_TOPIC"
  check_echo_once "$RGB_TOPIC"
  check_echo_once "$DEPTH_TOPIC"
  if [[ -n "$DEPTH_CAMERA_INFO_TOPIC" ]]; then
    check_echo_once "$DEPTH_CAMERA_INFO_TOPIC"
  fi

  if topic_exists "$SCAN_TOPIC"; then
    check_hz "$SCAN_TOPIC"
  else
    warn "skipping hz, missing optional topic: $SCAN_TOPIC"
  fi
  check_hz "$RGB_TOPIC"
  check_hz "$DEPTH_TOPIC"

  log ""
  log "Summary: $pass_count passed, $fail_count failed"
  if [[ "$fail_count" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
