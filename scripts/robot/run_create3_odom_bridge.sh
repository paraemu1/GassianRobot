#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

ACTION="${1:-start}"
AUTONOMY_CONTAINER="${AUTONOMY_CONTAINER:-${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
BRIDGE_CONTAINER="${BRIDGE_CONTAINER:-create3_odom_bridge}"
BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${BRIDGE_PORT:-18912}"
AUTONOMY_TOPIC_ODOM="${AUTONOMY_TOPIC_ODOM:-/odom}"
ROBOT_TOPIC_ODOM="${ROBOT_TOPIC_ODOM:-/odom}"
ODOM_POLL_HZ="${ODOM_POLL_HZ:-120}"
ROBOT_IMAGE="${ROBOT_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}"
ROBOT_RMW_IMPLEMENTATION="${ROBOT_RMW_IMPLEMENTATION:-$GASSIAN_DEFAULT_RMW_IMPLEMENTATION}"
ROBOT_ROS_DOMAIN_ID="${ROBOT_ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_ROS_DOMAIN_ID}"
ROBOT_ROS_LOCALHOST_ONLY="${ROBOT_ROS_LOCALHOST_ONLY:-$GASSIAN_DEFAULT_ROS_LOCALHOST_ONLY}"
ROBOT_DDS_IFACE="${ROBOT_DDS_IFACE:-$GASSIAN_DEFAULT_DDS_IFACE}"
ROBOT_DDS_INCLUDE_LOOPBACK="${ROBOT_DDS_INCLUDE_LOOPBACK:-$GASSIAN_DEFAULT_DDS_INCLUDE_LOOPBACK}"
ROBOT_CYCLONEDDS_URI="${ROBOT_CYCLONEDDS_URI:-}"

if [[ -z "$ROBOT_CYCLONEDDS_URI" && "$ROBOT_RMW_IMPLEMENTATION" == "rmw_cyclonedds_cpp" ]]; then
  ROBOT_CYCLONEDDS_URI="$(build_cyclonedds_uri "$ROBOT_DDS_IFACE" "$ROBOT_DDS_INCLUDE_LOOPBACK")"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

bridge_receiver_running() {
  docker exec "$AUTONOMY_CONTAINER" bash -lc "pgrep -af 'create3_odom_bridg[e].py recv' >/dev/null"
}

bridge_sender_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "$BRIDGE_CONTAINER"
}

stop_bridge() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$BRIDGE_CONTAINER"; then
    docker rm -f "$BRIDGE_CONTAINER" >/dev/null
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$AUTONOMY_CONTAINER"; then
    docker exec "$AUTONOMY_CONTAINER" bash -lc "pkill -f 'create3_odom_bridg[e].py recv' >/dev/null 2>&1 || true"
  fi
}

status_bridge() {
  local ok=0

  if docker ps --format '{{.Names}}' | grep -Fxq "$AUTONOMY_CONTAINER"; then
    echo "[PASS] autonomy container running: $AUTONOMY_CONTAINER"
  else
    echo "[FAIL] autonomy container not running: $AUTONOMY_CONTAINER"
    ok=1
  fi

  if bridge_receiver_running 2>/dev/null; then
    echo "[PASS] odom receiver running in $AUTONOMY_CONTAINER"
  else
    echo "[FAIL] odom receiver not running in $AUTONOMY_CONTAINER"
    ok=1
  fi

  if bridge_sender_running; then
    echo "[PASS] robot odom bridge container running: $BRIDGE_CONTAINER"
  else
    echo "[FAIL] robot odom bridge container not running: $BRIDGE_CONTAINER"
    ok=1
  fi

  return "$ok"
}

start_bridge() {
  require_cmd docker

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker and retry." >&2
    exit 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -Fxq "$AUTONOMY_CONTAINER"; then
    echo "Autonomy runtime container is not running: $AUTONOMY_CONTAINER" >&2
    echo "Start it first: ./scripts/robot/run_robot_runtime_container.sh" >&2
    exit 1
  fi

  ensure_create3_usb_host_iface "$ROBOT_DDS_IFACE"
  ensure_dds_iface_exists "$ROBOT_DDS_IFACE"
  stop_bridge

  docker exec -d "$AUTONOMY_CONTAINER" bash -lc \
    "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && exec python3 ./scripts/robot/create3_odom_bridge.py recv --topic '$AUTONOMY_TOPIC_ODOM' --host '$BRIDGE_HOST' --port '$BRIDGE_PORT' --poll-hz '$ODOM_POLL_HZ'" \
    >/dev/null

  docker run -d --rm \
    --name "$BRIDGE_CONTAINER" \
    --network host \
    -v "${REPO_ROOT}:${CONTAINER_WORKDIR}" \
    -w "$CONTAINER_WORKDIR" \
    -e RMW_IMPLEMENTATION="$ROBOT_RMW_IMPLEMENTATION" \
    -e ROS_DOMAIN_ID="$ROBOT_ROS_DOMAIN_ID" \
    -e ROS_LOCALHOST_ONLY="$ROBOT_ROS_LOCALHOST_ONLY" \
    -e DDS_IFACE="$ROBOT_DDS_IFACE" \
    -e DDS_INCLUDE_LOOPBACK="$ROBOT_DDS_INCLUDE_LOOPBACK" \
    -e CYCLONEDDS_URI="$ROBOT_CYCLONEDDS_URI" \
    "$ROBOT_IMAGE" \
    bash -lc "source /opt/ros/humble/setup.bash && exec python3 ./scripts/robot/create3_odom_bridge.py send --topic '$ROBOT_TOPIC_ODOM' --host '$BRIDGE_HOST' --port '$BRIDGE_PORT'" \
    >/dev/null

  status_bridge
}

case "$ACTION" in
  start)
    start_bridge
    ;;
  stop)
    stop_bridge
    ;;
  restart)
    stop_bridge
    start_bridge
    ;;
  status)
    status_bridge
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
