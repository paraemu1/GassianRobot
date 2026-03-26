#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

ROBOT_IP="${ROBOT_IP:-192.168.186.2}"
ROBOT_IMAGE="${ROBOT_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}"
ROBOT_RMW_IMPLEMENTATION="${ROBOT_RMW_IMPLEMENTATION:-$GASSIAN_DEFAULT_RMW_IMPLEMENTATION}"
ROBOT_ROS_DOMAIN_ID="${ROBOT_ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_ROS_DOMAIN_ID}"
ROBOT_ROS_LOCALHOST_ONLY="${ROBOT_ROS_LOCALHOST_ONLY:-$GASSIAN_DEFAULT_ROS_LOCALHOST_ONLY}"
ROBOT_DDS_IFACE="${ROBOT_DDS_IFACE:-$GASSIAN_DEFAULT_DDS_IFACE}"
ROBOT_DDS_INCLUDE_LOOPBACK="${ROBOT_DDS_INCLUDE_LOOPBACK:-$GASSIAN_DEFAULT_DDS_INCLUDE_LOOPBACK}"
ROBOT_CYCLONEDDS_URI="${ROBOT_CYCLONEDDS_URI:-}"
TIMEOUT_SEC="${TIMEOUT_SEC:-12}"

if [[ -z "$ROBOT_CYCLONEDDS_URI" && "$ROBOT_RMW_IMPLEMENTATION" == "rmw_cyclonedds_cpp" ]]; then
  ROBOT_CYCLONEDDS_URI="$(build_cyclonedds_uri "$ROBOT_DDS_IFACE" "$ROBOT_DDS_INCLUDE_LOOPBACK")"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd docker
require_cmd curl
require_cmd ping
require_cmd timeout

ensure_create3_usb_host_iface "$ROBOT_DDS_IFACE"
ensure_dds_iface_exists "$ROBOT_DDS_IFACE"

if ! ping -I "$ROBOT_DDS_IFACE" -c 1 -W 1 "$ROBOT_IP" >/dev/null 2>&1; then
  echo "[FAIL] Create3 is unreachable on ${ROBOT_DDS_IFACE} (${ROBOT_IP})" >&2
  exit 1
fi

set +e
health_output="$(
  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="$ROBOT_RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROBOT_ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROBOT_ROS_LOCALHOST_ONLY" \
    -e CYCLONEDDS_URI="$ROBOT_CYCLONEDDS_URI" \
    "$ROBOT_IMAGE" \
    bash -lc '
      set -eo pipefail
      set +u
      source /opt/ros/humble/setup.bash
      set -u
      ros2 daemon stop >/dev/null 2>&1 || true
      bad=0

      pass(){ echo "[PASS] $*"; }
      fail(){ echo "[FAIL] $*"; bad=1; }
      warn(){ echo "[WARN] $*"; }

      cmd_vel_info="$(timeout '"$TIMEOUT_SEC"' ros2 topic info --no-daemon /cmd_vel 2>/dev/null || true)"
      cmd_vel_subs="$(printf "%s\n" "$cmd_vel_info" | awk "/Subscription count:/ {print \$3}")"
      if [[ -n "$cmd_vel_subs" && "$cmd_vel_subs" -ge 1 ]]; then
        pass "/cmd_vel has robot subscriber(s): $cmd_vel_subs"
      else
        fail "/cmd_vel has no robot subscriber"
      fi

      for topic in /stop_status /hazard_detection /kidnap_status; do
        if timeout '"$TIMEOUT_SEC"' ros2 topic info --no-daemon "$topic" >/dev/null 2>&1; then
          pass "topic present: $topic"
        else
          fail "topic missing: $topic"
        fi
      done

      if timeout '"$TIMEOUT_SEC"' ros2 topic info --no-daemon /scan >/dev/null 2>&1; then
        warn "/scan is present"
      else
        warn "/scan is absent (expected unless a laser source is configured)"
      fi

      timeout '"$TIMEOUT_SEC"' ros2 node list --no-daemon | grep -E "create|internal|motion|hazard|robot_state|mobility|stasis" | sort || true
      exit "$bad"
    ' 2>&1
)"
health_rc=$?
set -e

printf '%s\n' "$health_output"

if [[ "$health_rc" -eq 0 ]]; then
  exit 0
fi

echo ""
echo "Recent robot log tail:"
curl --interface "$ROBOT_DDS_IFACE" -sS -m 20 "http://${ROBOT_IP}/logs-raw" | tail -n 40 || true
exit "$health_rc"
