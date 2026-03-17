#!/usr/bin/env bash
set -euo pipefail

# Checks software prerequisites before running autonomous nav/scan mission.
# Safe to run with or without robot connected.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAYPOINT_FILE="${WAYPOINT_FILE:-${REPO_ROOT}/config/scan_waypoints_room_a.tsv}"
NEED_ROBOT="${NEED_ROBOT:-0}"

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

for s in \
  "${REPO_ROOT}/scripts/run_rtabmap_container.sh" \
  "${REPO_ROOT}/scripts/run_oak_camera.sh" \
  "${REPO_ROOT}/scripts/run_rtabmap_rgbd.sh" \
  "${REPO_ROOT}/scripts/run_nav2_with_rtabmap.sh" \
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

if docker image inspect gassian/ros2-humble-rtabmap:latest >/dev/null 2>&1; then
  pass "rtabmap image present"
else
  fail "rtabmap image missing"
fi

if [[ "$NEED_ROBOT" == "1" ]]; then
  if ip link show l4tbr0 >/dev/null 2>&1; then
    pass "l4tbr0 present"
  else
    fail "l4tbr0 missing"
  fi

  if ping -I l4tbr0 -c 1 -W 1 192.168.186.2 >/dev/null 2>&1; then
    pass "Create3 reachable (USB-C)"
  else
    fail "Create3 unreachable on USB-C"
  fi
else
  warn "Skipping hardware checks (set NEED_ROBOT=1 to enforce)"
fi

echo "Summary: pass=$ok fail=$bad"
[[ "$bad" -eq 0 ]]
