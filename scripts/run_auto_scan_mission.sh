#!/usr/bin/env bash
set -euo pipefail

# Automated Nav2 scan mission runner.
# Assumes ROS graph (RTAB-Map + Nav2 + robot) is already up.
# Reads waypoints TSV: x y qz qw hold_sec

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAYPOINT_FILE="${WAYPOINT_FILE:-${REPO_ROOT}/config/scan_waypoints_room_a.tsv}"
RUN_NAME="${RUN_NAME:-$(date +%F)-auto-room-scan}"
RUN_DIR="${REPO_ROOT}/runs/${RUN_NAME}"
DRY_RUN="${DRY_RUN:-0}"
START_RECORD="${START_RECORD:-0}"
VIDEO_SEC="${VIDEO_SEC:-120}"
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
CAPTURE_AT_WAYPOINT="${CAPTURE_AT_WAYPOINT:-1}"
CAPTURE_WIDTH="${CAPTURE_WIDTH:-1280}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-720}"
ROS_CONTAINER="${ROS_CONTAINER:-ros_humble_rtabmap}"
ROS_IMAGE="${ROS_IMAGE:-gassian/ros2-humble-rtabmap:latest}"

mkdir -p "${RUN_DIR}/logs" "${RUN_DIR}/raw"
LOG_FILE="${RUN_DIR}/logs/auto_scan_mission.log"

log(){ echo "[$(date +%T)] $*" | tee -a "$LOG_FILE"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || { log "missing command: $1"; exit 1; }; }

ros_send_goal() {
  local x="$1" y="$2" qz="$3" qw="$4"
  local payload="{pose: {header: {frame_id: map}, pose: {position: {x: $x, y: $y, z: 0.0}, orientation: {z: $qz, w: $qw}}}}"

  if command -v ros2 >/dev/null 2>&1; then
    ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose "$payload" --feedback
    return
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    docker exec -i "$ROS_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose '$payload' --feedback"
    return
  fi

  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}" \
    -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
    -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
    "$ROS_IMAGE" bash -lc "source /opt/ros/humble/setup.bash && ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose '$payload' --feedback"
}

send_goal_wait() {
  local x="$1" y="$2" qz="$3" qw="$4"

  log "goal -> x=$x y=$y qz=$qz qw=$qw"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: ros_send_goal $x $y $qz $qw"
    return 0
  fi

  set +e
  local out
  out="$(ros_send_goal "$x" "$y" "$qz" "$qw" 2>&1)"
  local rc=$?
  set -e
  echo "$out" >> "$LOG_FILE"

  if [[ "$rc" -ne 0 ]]; then
    log "goal command failed, rc=$rc"
    return 1
  fi

  if echo "$out" | grep -Eqi "aborted|rejected|canceled|failed"; then
    log "goal failed per action output"
    return 1
  fi

  log "goal command completed"
  return 0
}

main() {
  : > "$LOG_FILE"
  log "starting automated scan mission"
  log "run_dir=$RUN_DIR"
  log "waypoints=$WAYPOINT_FILE"
  log "dry_run=$DRY_RUN"

  require_cmd docker
  require_cmd python3

  if [[ ! -f "$WAYPOINT_FILE" ]]; then
    log "waypoint file missing: $WAYPOINT_FILE"
    exit 1
  fi

  if [[ "$START_RECORD" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY_RUN: would record video for ${VIDEO_SEC}s on ${VIDEO_DEVICE}"
    elif [[ -x "${REPO_ROOT}/scripts/record_oak_rgb_video.sh" ]]; then
      log "starting background recording"
      (
        cd "$REPO_ROOT"
        timeout "$VIDEO_SEC" ./scripts/record_oak_rgb_video.sh --output "${RUN_DIR}/raw/capture.mp4" --duration "$VIDEO_SEC"
      ) >> "$LOG_FILE" 2>&1 &
      log "recording pid=$!"
    else
      log "record script not found/executable; skipping recording"
    fi
  fi

  local line idx=0 x y qz qw hold
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    idx=$((idx+1))
    x="$(echo "$line" | awk '{print $1}')"
    y="$(echo "$line" | awk '{print $2}')"
    qz="$(echo "$line" | awk '{print $3}')"
    qw="$(echo "$line" | awk '{print $4}')"
    hold="$(echo "$line" | awk '{print $5}')"
    hold="${hold:-2}"

    log "waypoint #$idx: $x $y $qz $qw hold=${hold}s"
    if ! send_goal_wait "$x" "$y" "$qz" "$qw"; then
      log "mission failed at waypoint #$idx"
      exit 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY_RUN: sleep ${hold}s"
    else
      sleep "$hold"
      if [[ "$CAPTURE_AT_WAYPOINT" == "1" ]]; then
        local img="${RUN_DIR}/raw/waypoint_$(printf '%03d' "$idx").jpg"
        log "capturing still image: $img"
        set +e
        python3 "${REPO_ROOT}/scripts/capture_oak_still.py" \
          --output "$img" --width "$CAPTURE_WIDTH" --height "$CAPTURE_HEIGHT" >> "$LOG_FILE" 2>&1
        local c_rc=$?
        set -e
        if [[ "$c_rc" -ne 0 ]]; then
          log "still capture failed at waypoint #$idx (continuing)"
        fi
      fi
    fi
  done < "$WAYPOINT_FILE"

  log "mission complete"
}

main "$@"
