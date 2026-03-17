#!/usr/bin/env bash
set -euo pipefail

# One-command live launcher for autonomous scan.
# Starts RTAB-Map container shell, then tells operator what to run in each terminal,
# and executes preflight + mission from current ROS environment.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_NAME="${RUN_NAME:-$(date +%F)-auto-room-scan}"
WAYPOINT_FILE="${WAYPOINT_FILE:-${REPO_ROOT}/config/scan_waypoints_room_a.tsv}"

cat <<EOF
=== Live Auto-Scan Launcher ===
This script assumes Create 3 is connected via USB-C and safe floor area is ready.

Step A (Terminal 1):
  cd ${REPO_ROOT}
  ./scripts/run_rtabmap_container.sh
  # inside container:
  source /opt/ros/humble/setup.bash
  ./scripts/run_oak_camera.sh
  ./scripts/run_rtabmap_rgbd.sh

Step B (Terminal 2, ROS env with Nav2 available):
  cd ${REPO_ROOT}
  ./scripts/run_nav2_with_rtabmap.sh

Step C (Terminal 3, this script can continue after A/B are up):
  NEED_ROBOT=1 ./scripts/preflight_autonomy.sh
  RUN_NAME=${RUN_NAME} WAYPOINT_FILE=${WAYPOINT_FILE} ./scripts/run_auto_scan_mission.sh

EOF

read -rp "Run preflight+mission now in this terminal? [y/N]: " ans
if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

cd "$REPO_ROOT"
NEED_ROBOT=1 ./scripts/preflight_autonomy.sh
RUN_NAME="$RUN_NAME" WAYPOINT_FILE="$WAYPOINT_FILE" ./scripts/run_auto_scan_mission.sh
