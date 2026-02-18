#!/usr/bin/env bash
set -euo pipefail

# Quick headless ROS 2 health checks for Create 3 + LiDAR + OAK.
# Override defaults with env vars, e.g. TOPIC_IMAGE=/camera/image_raw ./scripts/ros_health_check.sh

TOPIC_TF="${TOPIC_TF:-/tf}"
TOPIC_ODOM="${TOPIC_ODOM:-/odom}"
TOPIC_SCAN="${TOPIC_SCAN:-/scan}"
TOPIC_CAMERA_INFO="${TOPIC_CAMERA_INFO:-/oak/rgb/camera_info}"
TOPIC_IMAGE="${TOPIC_IMAGE:-/oak/rgb/image_raw}"
TIMEOUT_SEC="${TIMEOUT_SEC:-8}"

pass_count=0
fail_count=0

log() { printf "%s\n" "$*"; }
pass() { log "[PASS] $*"; pass_count=$((pass_count + 1)); }
fail() { log "[FAIL] $*"; fail_count=$((fail_count + 1)); }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

topic_exists() {
  local topic="$1"
  ros2 topic list | grep -Fxq "$topic"
}

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

  log "ROS health check starting..."
  log "Topics:"
  log "  TF:          $TOPIC_TF"
  log "  ODOM:        $TOPIC_ODOM"
  log "  SCAN:        $TOPIC_SCAN"
  log "  CAMERA_INFO: $TOPIC_CAMERA_INFO"
  log "  IMAGE:       $TOPIC_IMAGE"
  log ""

  check_topic_exists "$TOPIC_TF"
  check_topic_exists "$TOPIC_ODOM"
  check_topic_exists "$TOPIC_SCAN"
  check_topic_exists "$TOPIC_CAMERA_INFO"
  check_topic_exists "$TOPIC_IMAGE"

  check_echo_once "$TOPIC_TF"
  check_echo_once "$TOPIC_ODOM"
  check_echo_once "$TOPIC_SCAN"
  check_echo_once "$TOPIC_CAMERA_INFO"
  check_echo_once "$TOPIC_IMAGE"

  check_hz "$TOPIC_SCAN"
  check_hz "$TOPIC_IMAGE"

  log ""
  log "Summary: $pass_count passed, $fail_count failed"
  if [[ "$fail_count" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
