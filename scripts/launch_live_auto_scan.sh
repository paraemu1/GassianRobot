#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

ACTION="${1:-start}"
RUN_NAME="${RUN_NAME:-$(date +%F-%H%M%S)-auto-room-scan}"
WAYPOINT_FILE="${WAYPOINT_FILE:-${REPO_ROOT}/config/scan_waypoints_room_a_conservative.tsv}"
RUN_DIR="${REPO_ROOT}/runs/${RUN_NAME}"
LOG_DIR="${RUN_DIR}/logs"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/robot_ws}"
AUTO_START_DOCKER="${AUTO_START_DOCKER:-1}"
AUTO_BUILD_RUNTIME_IMAGE="${AUTO_BUILD_RUNTIME_IMAGE:-1}"
DELETE_DB_ON_START="${DELETE_DB_ON_START:-true}"
RTABMAP_DB_PATH="${RTABMAP_DB_PATH:-${RUN_DIR}/rtabmap.db}"
START_MISSION_BY_DEFAULT="${START_MISSION_BY_DEFAULT:-1}"
MISSION_MODE="${MISSION_MODE:-local_stopgo}"
MISSION_DRY_RUN="${MISSION_DRY_RUN:-${DRY_RUN:-0}}"
MISSION_CAPTURE_AT_WAYPOINT="${MISSION_CAPTURE_AT_WAYPOINT:-1}"
MISSION_MIN_HOLD_SEC="${MISSION_MIN_HOLD_SEC:-3}"
MISSION_NAV2_BEHAVIOR_TREE="${MISSION_NAV2_BEHAVIOR_TREE:-/opt/ros/humble/share/nav2_bt_navigator/behavior_trees/navigate_w_replanning_only_if_path_becomes_invalid.xml}"
MISSION_FORCE_STOP_BETWEEN_WAYPOINTS="${MISSION_FORCE_STOP_BETWEEN_WAYPOINTS:-1}"
MISSION_GOAL_REACHED_MAX_ERROR_M="${MISSION_GOAL_REACHED_MAX_ERROR_M:-0.12}"
MISSION_GOAL_MAX_ATTEMPTS="${MISSION_GOAL_MAX_ATTEMPTS:-2}"
MISSION_CAPTURE_MIN_TRANSLATION_M="${MISSION_CAPTURE_MIN_TRANSLATION_M:-0.10}"
MISSION_POSE_QUERY_TIMEOUT_SEC="${MISSION_POSE_QUERY_TIMEOUT_SEC:-5}"
MISSION_REBASE_WAYPOINTS_ON_ACTUAL_POSE="${MISSION_REBASE_WAYPOINTS_ON_ACTUAL_POSE:-1}"
MISSION_DRIVE_SPEED_MPS="${MISSION_DRIVE_SPEED_MPS:-0.05}"
MISSION_SEGMENT_MIN_TRANSLATION_M="${MISSION_SEGMENT_MIN_TRANSLATION_M:-0.10}"
MISSION_RETURN_TO_ENTRY_AFTER_SURVEY="${MISSION_RETURN_TO_ENTRY_AFTER_SURVEY:-1}"
MISSION_SPIN_MIN_ANGLE_RAD="${MISSION_SPIN_MIN_ANGLE_RAD:-0.05}"
MISSION_SPIN_TIME_ALLOWANCE_SEC="${MISSION_SPIN_TIME_ALLOWANCE_SEC:-15}"
MISSION_DRIVE_TIME_ALLOWANCE_SEC_PER_M="${MISSION_DRIVE_TIME_ALLOWANCE_SEC_PER_M:-50}"
AUTO_DOCK_AFTER_MISSION="${AUTO_DOCK_AFTER_MISSION:-1}"
AUTO_STOP_AFTER_MISSION="${AUTO_STOP_AFTER_MISSION:-1}"
POST_MISSION_SETTLE_SEC="${POST_MISSION_SETTLE_SEC:-2}"
AUTO_UNDOCK_IF_DOCKED="${AUTO_UNDOCK_IF_DOCKED:-1}"
POST_UNDOCK_SETTLE_SEC="${POST_UNDOCK_SETTLE_SEC:-3}"
REQUIRE_MOTION_READY_BEFORE_MISSION="${REQUIRE_MOTION_READY_BEFORE_MISSION:-1}"
GENERATE_LIVE_WAYPOINTS="${GENERATE_LIVE_WAYPOINTS:-1}"
LIVE_WAYPOINT_PATTERN="${LIVE_WAYPOINT_PATTERN:-serpentine}"
LIVE_WAYPOINT_FORWARD_STEP_M="${LIVE_WAYPOINT_FORWARD_STEP_M:-0.18}"
LIVE_WAYPOINT_LANE_WIDTH_M="${LIVE_WAYPOINT_LANE_WIDTH_M:-0.18}"
LIVE_WAYPOINT_COLS="${LIVE_WAYPOINT_COLS:-3}"
LIVE_WAYPOINT_ROWS="${LIVE_WAYPOINT_ROWS:-4}"
LIVE_WAYPOINT_RETURN_TO_ENTRY="${LIVE_WAYPOINT_RETURN_TO_ENTRY:-0}"
START_ODOM_BRIDGE="${START_ODOM_BRIDGE:-1}"
REQUIRE_ODOM_BRIDGE_IN_PREFLIGHT="${REQUIRE_ODOM_BRIDGE_IN_PREFLIGHT:-1}"
VISUAL_ODOMETRY_FOR_AUTOSCAN="${VISUAL_ODOMETRY_FOR_AUTOSCAN:-false}"
RTABMAP_ODOM_TOPIC="${RTABMAP_ODOM_TOPIC:-/odom}"
RTABMAP_READY_TIMEOUT_SEC="${RTABMAP_READY_TIMEOUT_SEC:-90}"
NAV2_READY_TIMEOUT_SEC="${NAV2_READY_TIMEOUT_SEC:-90}"
RUNTIME_READY_TIMEOUT_SEC="${RUNTIME_READY_TIMEOUT_SEC:-30}"
CAMERA_READY_TIMEOUT_SEC="${CAMERA_READY_TIMEOUT_SEC:-45}"

apply_autonomy_local_defaults

usage() {
  cat <<EOF
Usage: ./scripts/launch_live_auto_scan.sh [start|start-only|mission|stop|status]

Default action: start

What "start" does:
  1. Starts Docker if needed
  2. Starts the robot runtime container
  3. Starts the Create 3 cmd_vel bridge
     and the odom bridge by default for stable motion estimation
  4. Starts OAK
  5. Starts RTAB-Map (defaulting to Create 3 odom for auto-scan) and saves its database to:
     ${RTABMAP_DB_PATH}
  6. Starts Nav2
  7. Runs the scan mission using:
     ${WAYPOINT_FILE}

Useful env vars:
  RUN_NAME=<name>                 Default: ${RUN_NAME}
  WAYPOINT_FILE=<path>            Default: ${WAYPOINT_FILE}
  RTABMAP_DB_PATH=<path>          Default: ${RTABMAP_DB_PATH}
  DELETE_DB_ON_START=true|false   Default: ${DELETE_DB_ON_START}
  AUTO_START_DOCKER=1|0           Default: ${AUTO_START_DOCKER}
  AUTO_BUILD_RUNTIME_IMAGE=1|0    Default: ${AUTO_BUILD_RUNTIME_IMAGE}
  START_ODOM_BRIDGE=1|0           Default: ${START_ODOM_BRIDGE}
  MISSION_MODE=local_stopgo|navigate_to_pose Default: ${MISSION_MODE}
  MISSION_DRY_RUN=1|0             Default: ${MISSION_DRY_RUN}
  MISSION_MIN_HOLD_SEC=<sec>      Default: ${MISSION_MIN_HOLD_SEC}
  MISSION_GOAL_REACHED_MAX_ERROR_M=<m> Default: ${MISSION_GOAL_REACHED_MAX_ERROR_M}
  MISSION_GOAL_MAX_ATTEMPTS=<n>   Default: ${MISSION_GOAL_MAX_ATTEMPTS}
  MISSION_CAPTURE_MIN_TRANSLATION_M=<m> Default: ${MISSION_CAPTURE_MIN_TRANSLATION_M}
  MISSION_REBASE_WAYPOINTS_ON_ACTUAL_POSE=1|0 Default: ${MISSION_REBASE_WAYPOINTS_ON_ACTUAL_POSE}
  MISSION_DRIVE_SPEED_MPS=<mps>   Default: ${MISSION_DRIVE_SPEED_MPS}
  MISSION_SEGMENT_MIN_TRANSLATION_M=<m> Default: ${MISSION_SEGMENT_MIN_TRANSLATION_M}
  MISSION_RETURN_TO_ENTRY_AFTER_SURVEY=1|0 Default: ${MISSION_RETURN_TO_ENTRY_AFTER_SURVEY}
  MISSION_SPIN_MIN_ANGLE_RAD=<rad> Default: ${MISSION_SPIN_MIN_ANGLE_RAD}
  GENERATE_LIVE_WAYPOINTS=1|0     Default: ${GENERATE_LIVE_WAYPOINTS}
  LIVE_WAYPOINT_PATTERN=box|serpentine Default: ${LIVE_WAYPOINT_PATTERN}
  LIVE_WAYPOINT_FORWARD_STEP_M=<m> Default: ${LIVE_WAYPOINT_FORWARD_STEP_M}
  LIVE_WAYPOINT_LANE_WIDTH_M=<m>  Default: ${LIVE_WAYPOINT_LANE_WIDTH_M}
  LIVE_WAYPOINT_COLS=<n>          Default: ${LIVE_WAYPOINT_COLS}
  LIVE_WAYPOINT_ROWS=<n>          Default: ${LIVE_WAYPOINT_ROWS}
  AUTO_DOCK_AFTER_MISSION=1|0     Default: ${AUTO_DOCK_AFTER_MISSION}
  AUTO_STOP_AFTER_MISSION=1|0     Default: ${AUTO_STOP_AFTER_MISSION}
  AUTO_UNDOCK_IF_DOCKED=1|0       Default: ${AUTO_UNDOCK_IF_DOCKED}
  REQUIRE_MOTION_READY_BEFORE_MISSION=1|0 Default: ${REQUIRE_MOTION_READY_BEFORE_MISSION}
  VISUAL_ODOMETRY_FOR_AUTOSCAN=true|false Default: ${VISUAL_ODOMETRY_FOR_AUTOSCAN}
EOF
}

log() {
  printf "[%s] %s\n" "$(date +%T)" "$*"
}

fail() {
  printf "[%s] ERROR: %s\n" "$(date +%T)" "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

containerize_repo_path() {
  local path="$1"

  if [[ "$path" == "$REPO_ROOT/"* ]]; then
    printf "%s/%s" "$CONTAINER_WORKDIR" "${path#$REPO_ROOT/}"
    return 0
  fi

  printf "%s" "$path"
}

runtime_container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"
}

ensure_docker_daemon() {
  require_cmd docker

  if docker info >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$AUTO_START_DOCKER" != "1" ]]; then
    fail "Docker daemon is not reachable. Start Docker or set AUTO_START_DOCKER=1."
  fi

  require_cmd sudo
  log "Docker daemon is not running. Starting docker, docker.socket, and containerd..."
  if ! sudo -n systemctl start docker docker.socket containerd >/dev/null 2>&1; then
    sudo systemctl start docker docker.socket containerd
  fi

  docker info >/dev/null 2>&1 || fail "Docker daemon is still unreachable after start attempt."
}

ensure_runtime_image() {
  local image="${ROS_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}"

  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$AUTO_BUILD_RUNTIME_IMAGE" != "1" ]]; then
    fail "Missing Docker image: $image. Build it with ./scripts/build_robot_runtime_image.sh or set AUTO_BUILD_RUNTIME_IMAGE=1."
  fi

  log "Missing Docker image $image. Building it now..."
  "${SCRIPT_DIR}/build_robot_runtime_image.sh"
}

wait_for_runtime_container() {
  local deadline=$((SECONDS + RUNTIME_READY_TIMEOUT_SEC))
  local container="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"

  while (( SECONDS < deadline )); do
    if runtime_container_running && docker exec "$container" bash -lc 'source /opt/ros/humble/setup.bash && command -v ros2 >/dev/null 2>&1'; then
      return 0
    fi
    sleep 1
  done

  fail "Runtime container did not become ready within ${RUNTIME_READY_TIMEOUT_SEC}s."
}

wait_for_topic_once() {
  local topic="$1"
  local timeout_sec="$2"
  local container="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"
  local deadline=$((SECONDS + timeout_sec))

  while (( SECONDS < deadline )); do
    if docker exec "$container" bash -lc "source /opt/ros/humble/setup.bash && timeout 4 ros2 topic echo --once '$topic' >/dev/null 2>&1"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_nav2_ready() {
  local container="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"
  local deadline=$((SECONDS + NAV2_READY_TIMEOUT_SEC))

  while (( SECONDS < deadline )); do
    if docker exec "$container" bash -lc "source /opt/ros/humble/setup.bash && ros2 action list | grep -Fxq /navigate_to_pose"; then
      return 0
    fi
    sleep 2
  done

  return 1
}

stop_runtime_processes() {
  local container="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"

  if ! runtime_container_running; then
    return 0
  fi

  docker exec "$container" bash -lc "\
    pkill -f 'depthai_ros_driver camera.launch.py' >/dev/null 2>&1 || true; \
    pkill -f 'component_container.*oak_container' >/dev/null 2>&1 || true; \
    pkill -f '/opt/ros/humble/lib/rtabmap_odom/' >/dev/null 2>&1 || true; \
    pkill -f '/opt/ros/humble/lib/rtabmap_slam/rtabmap' >/dev/null 2>&1 || true; \
    pkill -f 'rtabmap_launch' >/dev/null 2>&1 || true; \
    pkill -f '/opt/ros/humble/lib/nav2_' >/dev/null 2>&1 || true; \
    pkill -f 'navigation_launch.py' >/dev/null 2>&1 || true; \
    pkill -f 'rtabmap_odom_nav2_bridge.py' >/dev/null 2>&1 || true; \
    pkill -f 'create3_cmd_vel_bridg[e].py send' >/dev/null 2>&1 || true; \
    pkill -f 'create3_odom_bridg[e].py recv' >/dev/null 2>&1 || true"
}

start_runtime_container() {
  mkdir -p "$LOG_DIR"
  log "Starting robot runtime container..."
  "${SCRIPT_DIR}/run_robot_runtime_container.sh" </dev/null >"${LOG_DIR}/runtime_container.log" 2>&1
  wait_for_runtime_container
}

start_runtime_job() {
  local label="$1"
  local log_host="$2"
  local command="$3"
  local container="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"
  local log_container

  mkdir -p "$(dirname "$log_host")"
  log_container="$(containerize_repo_path "$log_host")"

  log "Starting ${label}..."
  docker exec -d "$container" bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && ${command} > '$log_container' 2>&1"
}

start_bridges() {
  log "Starting Create 3 cmd_vel bridge..."
  "${SCRIPT_DIR}/run_create3_cmd_vel_bridge.sh" restart
  if [[ "$START_ODOM_BRIDGE" == "1" ]]; then
    log "Starting Create 3 odom bridge..."
    "${SCRIPT_DIR}/run_create3_odom_bridge.sh" restart
  else
    log "Skipping Create 3 odom bridge; this leaves RTAB-Map on pure visual odometry."
  fi
}

run_preflight() {
  log "Running autonomy preflight..."
  NEED_ROBOT=1 \
  REQUIRE_ODOM_BRIDGE="$REQUIRE_ODOM_BRIDGE_IN_PREFLIGHT" \
    "${SCRIPT_DIR}/preflight_autonomy.sh"
}

start_oak() {
  start_runtime_job "OAK camera" "${LOG_DIR}/oak_camera.log" "./scripts/run_oak_camera.sh"
  wait_for_topic_once "/oak/rgb/image_raw" "$CAMERA_READY_TIMEOUT_SEC" || fail "OAK RGB topic did not become ready."
  wait_for_topic_once "/oak/rgb/camera_info" "$CAMERA_READY_TIMEOUT_SEC" || fail "OAK camera_info topic did not become ready."
  log "OAK camera topics are live."
}

start_rtabmap() {
  local db_path_container

  db_path_container="$(containerize_repo_path "$RTABMAP_DB_PATH")"
  start_runtime_job \
    "RTAB-Map" \
    "${LOG_DIR}/rtabmap.log" \
    "DELETE_DB_ON_START=${DELETE_DB_ON_START} VISUAL_ODOMETRY=${VISUAL_ODOMETRY_FOR_AUTOSCAN} RTABMAP_DB_PATH=${db_path_container} ./scripts/run_rtabmap_rgbd.sh"

  wait_for_topic_once "$RTABMAP_ODOM_TOPIC" "$RTABMAP_READY_TIMEOUT_SEC" || fail "RTAB-Map odom topic did not become ready on ${RTABMAP_ODOM_TOPIC}."
  log "Waiting for RTAB-Map sync and TF readiness..."
  CHECK_MAP_ODOM_TF=1 RTABMAP_READY_TIMEOUT_SEC="$RTABMAP_READY_TIMEOUT_SEC" "${SCRIPT_DIR}/check_rtabmap_sync.sh" || fail "RTAB-Map sync check failed."
  log "RTAB-Map is ready. Database path: ${RTABMAP_DB_PATH}"
}

start_nav2() {
  start_runtime_job "Nav2" "${LOG_DIR}/nav2.log" "./scripts/run_nav2_with_rtabmap.sh"
  wait_for_nav2_ready || fail "Nav2 did not expose /navigate_to_pose within ${NAV2_READY_TIMEOUT_SEC}s."
  log "Nav2 is ready."
}

run_stack_health() {
  log "Running ROS health check..."
  "${SCRIPT_DIR}/ros_health_check.sh"
}

generate_live_waypoints() {
  local output_host="$1"
  local output_container
  local container="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"

  runtime_container_running || fail "Runtime container is not running; cannot generate live mission waypoints."
  output_container="$(containerize_repo_path "$output_host")"

  log "Generating live waypoint file from current RTAB-Map pose..."
  docker exec "$container" bash -lc "source /opt/ros/humble/setup.bash && cd '$CONTAINER_WORKDIR' && python3 ./scripts/generate_live_scan_waypoints.py --output '$output_container' --pattern '$LIVE_WAYPOINT_PATTERN' --forward-step '$LIVE_WAYPOINT_FORWARD_STEP_M' --lane-width '$LIVE_WAYPOINT_LANE_WIDTH_M' --cols '$LIVE_WAYPOINT_COLS' --rows '$LIVE_WAYPOINT_ROWS' --return-to-entry '$LIVE_WAYPOINT_RETURN_TO_ENTRY' --hold-sec '$MISSION_MIN_HOLD_SEC'"
}

run_mission() {
  local mission_waypoint_file="$WAYPOINT_FILE"

  mkdir -p "$RUN_DIR" "$LOG_DIR"
  log "Starting autonomous scan mission..."
  log "Run directory: ${RUN_DIR}"
  log "RTAB-Map DB:   ${RTABMAP_DB_PATH}"

  if [[ "$MISSION_DRY_RUN" == "1" ]]; then
    log "MISSION_DRY_RUN=1; skipping undock and leaving current dock state unchanged."
  elif [[ "$AUTO_UNDOCK_IF_DOCKED" == "1" ]]; then
    log "Checking dock status before mission..."
    bash "${SCRIPT_DIR}/create3_dock_control.sh" undock
    if [[ "$POST_UNDOCK_SETTLE_SEC" != "0" ]]; then
      log "Waiting ${POST_UNDOCK_SETTLE_SEC}s for post-undock settle..."
      sleep "$POST_UNDOCK_SETTLE_SEC"
    fi
  fi

  if [[ "$MISSION_DRY_RUN" != "1" && "$REQUIRE_MOTION_READY_BEFORE_MISSION" == "1" ]]; then
    log "Checking Create 3 motion readiness before mission..."
    if ! bash "${SCRIPT_DIR}/create3_motion_ready_check.sh" >/tmp/create3_motion_ready_check.out 2>&1; then
      sed -n '1,80p' /tmp/create3_motion_ready_check.out >&2 || true
      fail "Create 3 is not motion-ready for the scan mission."
    fi
    sed -n '1,20p' /tmp/create3_motion_ready_check.out
  fi

  if [[ "$GENERATE_LIVE_WAYPOINTS" == "1" ]]; then
    mission_waypoint_file="${RUN_DIR}/live_scan_waypoints.tsv"
    generate_live_waypoints "$mission_waypoint_file"
  fi

  log "Waypoint file: ${mission_waypoint_file}"

  local mission_script
  case "$MISSION_MODE" in
    local_stopgo)
      mission_script="${SCRIPT_DIR}/run_local_stopgo_scan_mission.sh"
      ;;
    navigate_to_pose)
      mission_script="${SCRIPT_DIR}/run_auto_scan_mission.sh"
      ;;
    *)
      fail "Unsupported MISSION_MODE=${MISSION_MODE}"
      ;;
  esac

  RUN_NAME="$RUN_NAME" \
  WAYPOINT_FILE="$mission_waypoint_file" \
  DRY_RUN="$MISSION_DRY_RUN" \
  CAPTURE_AT_WAYPOINT="$MISSION_CAPTURE_AT_WAYPOINT" \
  MIN_HOLD_SEC="$MISSION_MIN_HOLD_SEC" \
  GOAL_REACHED_MAX_ERROR_M="$MISSION_GOAL_REACHED_MAX_ERROR_M" \
  GOAL_MAX_ATTEMPTS="$MISSION_GOAL_MAX_ATTEMPTS" \
  CAPTURE_MIN_TRANSLATION_M="$MISSION_CAPTURE_MIN_TRANSLATION_M" \
  POSE_QUERY_TIMEOUT_SEC="$MISSION_POSE_QUERY_TIMEOUT_SEC" \
  REBASE_WAYPOINTS_ON_ACTUAL_POSE="$MISSION_REBASE_WAYPOINTS_ON_ACTUAL_POSE" \
  FORCE_STOP_BETWEEN_WAYPOINTS="$MISSION_FORCE_STOP_BETWEEN_WAYPOINTS" \
  NAV2_BEHAVIOR_TREE="$MISSION_NAV2_BEHAVIOR_TREE" \
  DRIVE_SPEED_MPS="$MISSION_DRIVE_SPEED_MPS" \
  SEGMENT_MIN_TRANSLATION_M="$MISSION_SEGMENT_MIN_TRANSLATION_M" \
  RETURN_TO_ENTRY_AFTER_SURVEY="$MISSION_RETURN_TO_ENTRY_AFTER_SURVEY" \
  SPIN_MIN_ANGLE_RAD="$MISSION_SPIN_MIN_ANGLE_RAD" \
  SPIN_TIME_ALLOWANCE_SEC="$MISSION_SPIN_TIME_ALLOWANCE_SEC" \
  DRIVE_TIME_ALLOWANCE_SEC_PER_M="$MISSION_DRIVE_TIME_ALLOWANCE_SEC_PER_M" \
    "$mission_script"
}

close_out_after_mission() {
  if [[ "$MISSION_DRY_RUN" == "1" ]]; then
    log "MISSION_DRY_RUN=1; skipping post-mission stop and dock closeout."
    return 0
  fi

  if [[ "$POST_MISSION_SETTLE_SEC" != "0" ]]; then
    log "Waiting ${POST_MISSION_SETTLE_SEC}s before closeout..."
    sleep "$POST_MISSION_SETTLE_SEC"
  fi

  if [[ "$AUTO_STOP_AFTER_MISSION" == "1" ]]; then
    log "Stopping autonomy stack after mission..."
    stop_stack
  fi

  if [[ "$AUTO_DOCK_AFTER_MISSION" == "1" ]]; then
    log "Docking robot after mission..."
    bash "${SCRIPT_DIR}/create3_dock_control.sh" dock
  fi
}

start_stack() {
  require_cmd bash
  require_cmd python3
  [[ -f "$WAYPOINT_FILE" ]] || fail "Waypoint file not found: $WAYPOINT_FILE"

  mkdir -p "$RUN_DIR" "$LOG_DIR"

  log "Live auto-scan run: ${RUN_NAME}"
  log "Logs: ${LOG_DIR}"
  log "Waypoint file: ${WAYPOINT_FILE}"
  log "RTAB-Map DB: ${RTABMAP_DB_PATH}"
  log "Robot assumptions: Create 3 connected on USB-C, robot on floor, clear scan area."

  ensure_docker_daemon
  ensure_runtime_image
  stop_stack >/dev/null 2>&1 || true
  start_runtime_container
  start_bridges
  run_preflight
  start_oak
  start_rtabmap
  run_stack_health
  start_nav2
}

stop_stack() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  "${SCRIPT_DIR}/run_create3_cmd_vel_bridge.sh" stop >/dev/null 2>&1 || true
  "${SCRIPT_DIR}/run_create3_odom_bridge.sh" stop >/dev/null 2>&1 || true
    stop_runtime_processes || true

    if runtime_container_running; then
      docker rm -f "${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}" >/dev/null 2>&1 || true
    fi
  fi
}

status_stack() {
  local container="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "[FAIL] Docker daemon is not running"
    return 1
  fi

  if runtime_container_running; then
    echo "[PASS] runtime container: $container"
  else
    echo "[FAIL] runtime container: $container"
  fi

  "${SCRIPT_DIR}/run_create3_cmd_vel_bridge.sh" status || true
  if [[ "$START_ODOM_BRIDGE" == "1" ]]; then
    "${SCRIPT_DIR}/run_create3_odom_bridge.sh" status || true
  fi

  if runtime_container_running; then
    docker exec "$container" bash -lc "pgrep -af 'depthai_ros_driver camera.launch.py|component_container.*oak_container|rtabmap.launch.py|navigation_launch.py|rtabmap_odom_nav2_bridge.py' || true"
    docker exec "$container" bash -lc "source /opt/ros/humble/setup.bash && ros2 action list | grep -Fx /navigate_to_pose || true"
  fi
}

case "$ACTION" in
  start)
    start_stack
    if [[ "$START_MISSION_BY_DEFAULT" == "1" ]]; then
      run_mission
      close_out_after_mission
    fi
    ;;
  start-only)
    start_stack
    ;;
  mission)
    run_mission
    close_out_after_mission
    ;;
  stop)
    stop_stack
    log "Live auto-scan stack stopped."
    ;;
  status)
    status_stack
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
