#!/usr/bin/env bash
set -euo pipefail

# Checks software prerequisites before running autonomous nav/scan mission.
# Safe to run with or without robot connected.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"
WAYPOINT_FILE="${WAYPOINT_FILE:-${REPO_ROOT}/config/scan_waypoints_room_a_conservative.tsv}"
NEED_ROBOT="${NEED_ROBOT:-0}"
REQUIRE_CMD_VEL_BRIDGE="${REQUIRE_CMD_VEL_BRIDGE:-1}"
REQUIRE_ODOM_BRIDGE="${REQUIRE_ODOM_BRIDGE:-1}"
REQUIRE_CREATE3_BASE_HEALTH="${REQUIRE_CREATE3_BASE_HEALTH:-1}"
CREATE3_BASE_HEALTH_TIMEOUT_SEC="${CREATE3_BASE_HEALTH_TIMEOUT_SEC:-90}"
CREATE3_BASE_HEALTH_RETRY_SEC="${CREATE3_BASE_HEALTH_RETRY_SEC:-5}"

ok=0
bad=0

pass(){ echo "[PASS] $*"; ok=$((ok+1)); }
fail(){ echo "[FAIL] $*"; bad=$((bad+1)); }
warn(){ echo "[WARN] $*"; }

must_cmd(){ command -v "$1" >/dev/null 2>&1 && pass "command: $1" || fail "missing command: $1"; }
must_file(){ [[ -f "$1" ]] && pass "file: $1" || fail "missing file: $1"; }

must_cmd docker
must_cmd bash
must_cmd python3

wait_for_create3_base_health() {
  local output_file="$1"
  local deadline=$((SECONDS + CREATE3_BASE_HEALTH_TIMEOUT_SEC))
  local attempt=1

  while (( SECONDS < deadline )); do
    if "${REPO_ROOT}/scripts/create3_base_health_check.sh" >"$output_file" 2>&1; then
      return 0
    fi

    warn "Create3 base ROS interface not ready yet (attempt ${attempt}); retrying in ${CREATE3_BASE_HEALTH_RETRY_SEC}s"
    attempt=$((attempt + 1))
    sleep "$CREATE3_BASE_HEALTH_RETRY_SEC"
  done

  "${REPO_ROOT}/scripts/create3_base_health_check.sh" >"$output_file" 2>&1 || true
  return 1
}

for s in \
  "${REPO_ROOT}/scripts/run_robot_runtime_container.sh" \
  "${REPO_ROOT}/scripts/run_oak_camera.sh" \
  "${REPO_ROOT}/scripts/run_rtabmap_rgbd.sh" \
  "${REPO_ROOT}/scripts/run_nav2_with_rtabmap.sh" \
  "${REPO_ROOT}/scripts/run_create3_cmd_vel_bridge.sh" \
  "${REPO_ROOT}/scripts/run_create3_odom_bridge.sh" \
  "${REPO_ROOT}/scripts/create3_dock_control.sh" \
  "${REPO_ROOT}/scripts/create3_base_health_check.sh" \
  "${REPO_ROOT}/scripts/create3_motion_ready_check.sh" \
  "${REPO_ROOT}/scripts/send_nav2_goal.sh" \
  "${REPO_ROOT}/scripts/record_oak_rgb_video.sh"; do
  must_file "$s"
done

must_file "$WAYPOINT_FILE"

if docker info >/dev/null 2>&1; then
  pass "docker daemon reachable"
else
  fail "docker daemon unreachable"
fi

if docker image inspect gassian/robot-runtime:latest >/dev/null 2>&1 || \
   docker image inspect gassian/ros2-humble-rtabmap:latest >/dev/null 2>&1; then
  pass "robot runtime image present"
else
  fail "robot runtime image missing"
fi

if [[ "$NEED_ROBOT" == "1" ]]; then
  if ip link show l4tbr0 >/dev/null 2>&1; then
    pass "l4tbr0 present"
  else
    fail "l4tbr0 missing"
  fi

  if ensure_create3_usb_host_iface l4tbr0 >/tmp/create3_usb_iface_recover.out 2>&1; then
    pass "l4tbr0 host address configured"
  else
    fail "l4tbr0 host address not configured"
    sed -n '1,40p' /tmp/create3_usb_iface_recover.out || true
  fi

  if ping -I l4tbr0 -c 1 -W 1 192.168.186.2 >/dev/null 2>&1; then
    pass "Create3 reachable (USB-C)"
  else
    fail "Create3 unreachable on USB-C"
  fi

  if [[ "$REQUIRE_CREATE3_BASE_HEALTH" == "1" ]]; then
    if wait_for_create3_base_health /tmp/create3_base_health.out; then
      pass "Create3 base ROS interface healthy"
    else
      fail "Create3 base ROS interface unhealthy"
      sed -n '1,80p' /tmp/create3_base_health.out || true
    fi
  else
    warn "Skipping Create3 base ROS health check (set REQUIRE_CREATE3_BASE_HEALTH=1 to enforce)"
  fi

  if [[ "$REQUIRE_CMD_VEL_BRIDGE" == "1" ]]; then
    if "${REPO_ROOT}/scripts/run_create3_cmd_vel_bridge.sh" status >/tmp/create3_cmd_vel_bridge.out 2>&1; then
      pass "Create3 cmd_vel bridge running"
    else
      fail "Create3 cmd_vel bridge not running"
      sed -n '1,40p' /tmp/create3_cmd_vel_bridge.out || true
    fi
  else
    warn "Skipping cmd_vel bridge check (set REQUIRE_CMD_VEL_BRIDGE=1 to enforce)"
  fi

  if [[ "$REQUIRE_ODOM_BRIDGE" == "1" ]]; then
    if "${REPO_ROOT}/scripts/run_create3_odom_bridge.sh" status >/tmp/create3_odom_bridge.out 2>&1; then
      pass "Create3 odom bridge running"
    else
      fail "Create3 odom bridge not running"
      sed -n '1,40p' /tmp/create3_odom_bridge.out || true
    fi
  else
    warn "Skipping odom bridge check (set REQUIRE_ODOM_BRIDGE=1 to enforce)"
  fi
else
  warn "Skipping hardware checks (set NEED_ROBOT=1 to enforce)"
fi

echo "Summary: pass=$ok fail=$bad"
[[ "$bad" -eq 0 ]]
