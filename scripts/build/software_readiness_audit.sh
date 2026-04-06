#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${REPO_ROOT}/runs/system_audit"
mkdir -p "$OUT_DIR"
STAMP="$(date +%F_%H%M%S)"
OUT_FILE="${OUT_DIR}/audit_${STAMP}.txt"

pass=0
fail=0
warn=0

p() { echo "[PASS] $*" | tee -a "$OUT_FILE"; pass=$((pass+1)); }
w() { echo "[WARN] $*" | tee -a "$OUT_FILE"; warn=$((warn+1)); }
f() { echo "[FAIL] $*" | tee -a "$OUT_FILE"; fail=$((fail+1)); }

check_cmd() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then p "command present: $c"; else f "command missing: $c"; fi
}

{
  echo "# GassianRobot software readiness audit"
  echo "timestamp: $(date -Iseconds)"
  echo "repo: $REPO_ROOT"
  echo ""
} > "$OUT_FILE"

check_cmd docker
check_cmd python3
check_cmd bash
check_cmd ip
check_cmd ping
if command -v whiptail >/dev/null 2>&1; then p "command present: whiptail"; else w "command missing: whiptail (operator TUI falls back to plain text)"; fi

if docker info >/dev/null 2>&1; then
  p "docker daemon reachable"
else
  f "docker daemon not reachable"
fi

for img in gassian/robot-runtime:latest gassian/ros2-humble-rtabmap:latest gassian/gsplat-train:latest; do
  if docker image inspect "$img" >/dev/null 2>&1; then p "docker image present: $img"; else w "docker image missing: $img"; fi
done

mapfile -t ROOT_TUI_SCRIPTS < <(find "${REPO_ROOT}/scripts" -maxdepth 1 -type f -name '*.sh' | sort)
if [[ "${#ROOT_TUI_SCRIPTS[@]}" -eq 1 && "$(basename "${ROOT_TUI_SCRIPTS[0]}")" == "master_tui.sh" ]]; then
  p "scripts/ root keeps a single shell launcher: scripts/master_tui.sh"
else
  f "scripts/ root shell launchers are not normalized: ${ROOT_TUI_SCRIPTS[*]}"
fi

for s in \
  scripts/master_tui.sh \
  scripts/master_ncurses_tui.py \
  scripts/robot/teleop_drive_app.sh \
  scripts/robot/teleop_drive_app.py \
  scripts/robot/launch_live_auto_scan.sh \
  scripts/robot/run_robot_runtime_container.sh \
  scripts/robot/run_create3_cmd_vel_bridge.sh \
  scripts/robot/create3_base_health_check.sh \
  scripts/robot/run_nav2_with_rtabmap.sh \
  scripts/robot/run_rtabmap_rgbd.sh \
  scripts/robot/send_nav2_goal.sh \
  scripts/robot/run_auto_scan_mission.sh; do
  if [[ -f "$REPO_ROOT/$s" ]]; then p "file exists: $s"; else f "missing file: $s"; fi
done

for s in scripts/master_tui.sh; do
  if [[ -x "$REPO_ROOT/$s" ]]; then
    p "executable: $s"
  else
    w "not executable: $s"
  fi
done

if ip link show l4tbr0 >/dev/null 2>&1; then
  p "network iface present: l4tbr0"
  state="$(cat /sys/class/net/l4tbr0/operstate 2>/dev/null || true)"
  if [[ "$state" == "up" ]]; then p "l4tbr0 is up"; else w "l4tbr0 not up (state=$state)"; fi
else
  w "network iface missing: l4tbr0"
fi

if ping -I l4tbr0 -c 1 -W 1 192.168.186.2 >/dev/null 2>&1; then
  p "Create3 reachable on USB-C endpoint"
else
  w "Create3 not reachable right now (expected if disconnected)"
fi

avail_kb="$(df -Pk "$REPO_ROOT" | awk 'NR==2{print $4}')"
if [[ "$avail_kb" -gt 5242880 ]]; then
  p "disk free > 5GB"
else
  w "disk free < 5GB"
fi

echo "" | tee -a "$OUT_FILE"
echo "Summary: pass=$pass warn=$warn fail=$fail" | tee -a "$OUT_FILE"
echo "Report: $OUT_FILE" | tee -a "$OUT_FILE"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
