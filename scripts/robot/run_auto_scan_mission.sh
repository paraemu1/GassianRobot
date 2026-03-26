#!/usr/bin/env bash
set -euo pipefail

# Automated Nav2 scan mission runner.
# Assumes the local autonomy graph (RTAB-Map + Nav2) and the Create 3 cmd_vel bridge are already up.
# Reads waypoints TSV: x y qz qw hold_sec

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/common_ros.sh
source "${SCRIPT_DIR}/../lib/common_ros.sh"

WAYPOINT_FILE="${WAYPOINT_FILE:-${REPO_ROOT}/config/scan_waypoints_room_a_conservative.tsv}"
RUN_NAME="${RUN_NAME:-$(date +%F)-auto-room-scan}"
RUN_DIR="${REPO_ROOT}/runs/${RUN_NAME}"
DRY_RUN="${DRY_RUN:-0}"
START_RECORD="${START_RECORD:-0}"
VIDEO_SEC="${VIDEO_SEC:-120}"
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
CAPTURE_AT_WAYPOINT="${CAPTURE_AT_WAYPOINT:-1}"
CAPTURE_WIDTH="${CAPTURE_WIDTH:-1280}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-720}"
MIN_HOLD_SEC="${MIN_HOLD_SEC:-0}"
FORCE_STOP_BETWEEN_WAYPOINTS="${FORCE_STOP_BETWEEN_WAYPOINTS:-1}"
NAV2_BEHAVIOR_TREE="${NAV2_BEHAVIOR_TREE:-/opt/ros/humble/share/nav2_bt_navigator/behavior_trees/navigate_w_replanning_only_if_path_becomes_invalid.xml}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
POSE_QUERY_TIMEOUT_SEC="${POSE_QUERY_TIMEOUT_SEC:-5}"
GOAL_REACHED_MAX_ERROR_M="${GOAL_REACHED_MAX_ERROR_M:-0.12}"
GOAL_MAX_ATTEMPTS="${GOAL_MAX_ATTEMPTS:-2}"
CAPTURE_MIN_TRANSLATION_M="${CAPTURE_MIN_TRANSLATION_M:-0.10}"
REBASE_WAYPOINTS_ON_ACTUAL_POSE="${REBASE_WAYPOINTS_ON_ACTUAL_POSE:-1}"

apply_autonomy_local_defaults

mkdir -p "${RUN_DIR}/logs" "${RUN_DIR}/raw"
LOG_FILE="${RUN_DIR}/logs/auto_scan_mission.log"
CAPTURE_POSE_LOG="${RUN_DIR}/raw/capture_poses.tsv"

log(){ echo "[$(date +%T)] $*" | tee -a "$LOG_FILE"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || { log "missing command: $1"; exit 1; }; }

containerize_repo_path() {
  local path="$1"

  if [[ "$path" == "$REPO_ROOT/"* ]]; then
    printf "%s/%s" "${CONTAINER_WORKDIR:-/robot_ws}" "${path#$REPO_ROOT/}"
    return 0
  fi

  printf "%s" "$path"
}

enforce_min_hold() {
  local requested_hold="$1"

  awk -v requested="$requested_hold" -v minimum="$MIN_HOLD_SEC" 'BEGIN {
    if ((requested + 0.0) < (minimum + 0.0)) {
      printf "%g", minimum + 0.0
    } else {
      printf "%g", requested + 0.0
    }
  }'
}

parse_pose_line() {
  printf '%s\n' "$1" | awk '
    /^[+-]?[0-9.]+([eE][+-]?[0-9]+)? [+-]?[0-9.]+([eE][+-]?[0-9]+)? [+-]?[0-9.]+([eE][+-]?[0-9]+)? [^[:space:]]+$/ {
      line = $0
    }
    END {
      if (line != "") {
        print line
      }
    }'
}

distance_between_points() {
  local x1="$1" y1="$2" x2="$3" y2="$4"

  awk -v x1="$x1" -v y1="$y1" -v x2="$x2" -v y2="$y2" 'BEGIN {
    dx = (x1 + 0.0) - (x2 + 0.0)
    dy = (y1 + 0.0) - (y2 + 0.0)
    printf "%.6f", sqrt(dx * dx + dy * dy)
  }'
}

rebase_waypoint_from_last_actual() {
  local last_actual_x="$1" last_actual_y="$2" previous_planned_x="$3" previous_planned_y="$4" planned_x="$5" planned_y="$6"

  awk \
    -v last_actual_x="$last_actual_x" \
    -v last_actual_y="$last_actual_y" \
    -v previous_planned_x="$previous_planned_x" \
    -v previous_planned_y="$previous_planned_y" \
    -v planned_x="$planned_x" \
    -v planned_y="$planned_y" \
    'BEGIN {
      dx = (planned_x + 0.0) - (previous_planned_x + 0.0)
      dy = (planned_y + 0.0) - (previous_planned_y + 0.0)
      printf "%.6f %.6f", (last_actual_x + 0.0) + dx, (last_actual_y + 0.0) + dy
    }'
}

float_gt() {
  local lhs="$1" rhs="$2"

  awk -v lhs="$lhs" -v rhs="$rhs" 'BEGIN {
    exit !((lhs + 0.0) > (rhs + 0.0))
  }'
}

query_robot_pose() {
  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    docker exec "$ROS_CONTAINER" bash -lc \
      "source /opt/ros/humble/setup.bash && cd '${CONTAINER_WORKDIR:-/robot_ws}' && python3 ./scripts/robot/get_robot_map_pose.py --timeout-sec '$POSE_QUERY_TIMEOUT_SEC'"
    return
  fi

  if command -v ros2 >/dev/null 2>&1; then
    python3 "${REPO_ROOT}/scripts/robot/get_robot_map_pose.py" --timeout-sec "$POSE_QUERY_TIMEOUT_SEC"
    return
  fi

  docker run --rm --network host \
    -v "${REPO_ROOT}:${CONTAINER_WORKDIR:-/robot_ws}" \
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_AUTONOMY_ROS_DOMAIN_ID}" \
    -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
    -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
    "$ROS_IMAGE" bash -lc \
      "source /opt/ros/humble/setup.bash && cd '${CONTAINER_WORKDIR:-/robot_ws}' && python3 ./scripts/robot/get_robot_map_pose.py --timeout-sec '$POSE_QUERY_TIMEOUT_SEC'"
}

POSE_X=""
POSE_Y=""
POSE_YAW=""
POSE_SOURCE=""
LAST_ACTUAL_X=""
LAST_ACTUAL_Y=""
PREVIOUS_PLANNED_X=""
PREVIOUS_PLANNED_Y=""

read_robot_pose() {
  local out rc pose_line

  set +e
  out="$(query_robot_pose 2>&1)"
  rc=$?
  set -e
  echo "$out" >> "$LOG_FILE"

  if [[ "$rc" -ne 0 ]]; then
    log "robot pose query failed, rc=$rc"
    return 1
  fi

  pose_line="$(parse_pose_line "$out")"
  if [[ -z "$pose_line" ]]; then
    log "robot pose query returned no parseable pose line"
    return 1
  fi

  read -r POSE_X POSE_Y POSE_YAW POSE_SOURCE <<< "$pose_line"
  return 0
}

verify_goal_reached() {
  local goal_x="$1" goal_y="$2"
  local goal_error

  read_robot_pose || return 1
  goal_error="$(distance_between_points "$POSE_X" "$POSE_Y" "$goal_x" "$goal_y")"
  log "post-goal pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE goal_error=${goal_error}m"

  if float_gt "$goal_error" "$GOAL_REACHED_MAX_ERROR_M"; then
    log "goal error ${goal_error}m exceeds ${GOAL_REACHED_MAX_ERROR_M}m"
    return 1
  fi

  return 0
}

nearest_prior_capture_distance() {
  local pose_x="$1" pose_y="$2"

  awk -v x="$pose_x" -v y="$pose_y" '
    BEGIN {
      min = -1
    }
    /^[[:space:]]*#/ || NF < 3 {
      next
    }
    {
      dx = ($2 + 0.0) - (x + 0.0)
      dy = ($3 + 0.0) - (y + 0.0)
      distance = sqrt(dx * dx + dy * dy)
      if (min < 0 || distance < min) {
        min = distance
      }
    }
    END {
      if (min < 0) {
        print "none"
      } else {
        printf "%.6f", min
      }
    }' "$CAPTURE_POSE_LOG"
}

record_capture_pose() {
  local idx="$1" pose_x="$2" pose_y="$3" pose_yaw="$4" pose_source="$5" image_path="$6"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$idx" "$pose_x" "$pose_y" "$pose_yaw" "$pose_source" "$image_path" >> "$CAPTURE_POSE_LOG"
}

ros_send_goal() {
  local x="$1" y="$2" qz="$3" qw="$4"
  local payload

  if [[ -n "$NAV2_BEHAVIOR_TREE" ]]; then
    payload="{pose: {header: {frame_id: map}, pose: {position: {x: $x, y: $y, z: 0.0}, orientation: {z: $qz, w: $qw}}}, behavior_tree: \"$NAV2_BEHAVIOR_TREE\"}"
  else
    payload="{pose: {header: {frame_id: map}, pose: {position: {x: $x, y: $y, z: 0.0}, orientation: {z: $qz, w: $qw}}}}"
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    docker exec "$ROS_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose '$payload' --feedback"
    return
  fi

  if command -v ros2 >/dev/null 2>&1; then
    ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose "$payload" --feedback
    return
  fi

  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_AUTONOMY_ROS_DOMAIN_ID}" \
    -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
    -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
    "$ROS_IMAGE" bash -lc "source /opt/ros/humble/setup.bash && ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose '$payload' --feedback"
}

ros_publish_zero_cmd_vel() {
  local payload="{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}"

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    docker exec "$ROS_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist '$payload'" >/dev/null 2>&1
    return
  fi

  if command -v ros2 >/dev/null 2>&1; then
    ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "$payload" >/dev/null 2>&1
    return
  fi

  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_AUTONOMY_ROS_DOMAIN_ID}" \
    -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
    -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
    "$ROS_IMAGE" bash -lc "source /opt/ros/humble/setup.bash && ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist '$payload'" >/dev/null 2>&1
}

capture_still_image() {
  local output_host="$1"
  local output_container

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    output_container="$(containerize_repo_path "$output_host")"
    docker exec "$ROS_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && cd '${CONTAINER_WORKDIR:-/robot_ws}' && python3 ./scripts/robot/capture_oak_still.py --output '$output_container' --width '$CAPTURE_WIDTH' --height '$CAPTURE_HEIGHT'"
    return
  fi

  python3 "${REPO_ROOT}/scripts/robot/capture_oak_still.py" \
    --output "$output_host" --width "$CAPTURE_WIDTH" --height "$CAPTURE_HEIGHT"
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
  log "min_hold_sec=$MIN_HOLD_SEC"
  log "force_stop_between_waypoints=$FORCE_STOP_BETWEEN_WAYPOINTS"
  log "nav2_behavior_tree=${NAV2_BEHAVIOR_TREE:-<default>}"
  log "goal_reached_max_error_m=$GOAL_REACHED_MAX_ERROR_M"
  log "goal_max_attempts=$GOAL_MAX_ATTEMPTS"
  log "capture_min_translation_m=$CAPTURE_MIN_TRANSLATION_M"
  log "rebase_waypoints_on_actual_pose=$REBASE_WAYPOINTS_ON_ACTUAL_POSE"

  printf '# idx\tx\ty\tyaw\tsource\timage_path\n' > "$CAPTURE_POSE_LOG"

  require_cmd docker
  require_cmd python3

  if [[ "$REQUIRE_DDS_IFACE" == "1" ]]; then
    ensure_dds_iface_exists "$DDS_IFACE"
  fi

  if [[ ! -f "$WAYPOINT_FILE" ]]; then
    log "waypoint file missing: $WAYPOINT_FILE"
    exit 1
  fi

  if [[ "$START_RECORD" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY_RUN: would record video for ${VIDEO_SEC}s on ${VIDEO_DEVICE}"
    elif [[ -x "${REPO_ROOT}/scripts/robot/record_oak_rgb_video.sh" ]]; then
      log "starting background recording"
      (
        cd "$REPO_ROOT"
        timeout "$VIDEO_SEC" ./scripts/robot/record_oak_rgb_video.sh --output "${RUN_DIR}/raw/capture.mp4" --duration "$VIDEO_SEC"
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
    hold="$(enforce_min_hold "$hold")"

    local planned_x="$x" planned_y="$y" target_x target_y
    target_x="$planned_x"
    target_y="$planned_y"
    if [[ "$REBASE_WAYPOINTS_ON_ACTUAL_POSE" == "1" && "$DRY_RUN" != "1" && -n "$PREVIOUS_PLANNED_X" && -n "$LAST_ACTUAL_X" ]]; then
      read -r target_x target_y <<< "$(rebase_waypoint_from_last_actual "$LAST_ACTUAL_X" "$LAST_ACTUAL_Y" "$PREVIOUS_PLANNED_X" "$PREVIOUS_PLANNED_Y" "$planned_x" "$planned_y")"
      log "waypoint #$idx: planned=$planned_x,$planned_y rebased=$target_x,$target_y qz=$qz qw=$qw hold=${hold}s"
    else
      log "waypoint #$idx: target=$target_x,$target_y qz=$qz qw=$qw hold=${hold}s"
    fi
    local attempt goal_verified=0
    for ((attempt = 1; attempt <= GOAL_MAX_ATTEMPTS; attempt++)); do
      log "waypoint #$idx attempt ${attempt}/${GOAL_MAX_ATTEMPTS}"
      if ! send_goal_wait "$target_x" "$target_y" "$qz" "$qw"; then
        log "mission failed at waypoint #$idx"
        exit 1
      fi
      if [[ "$DRY_RUN" == "1" ]]; then
        goal_verified=1
        break
      fi
      if verify_goal_reached "$target_x" "$target_y"; then
        goal_verified=1
        LAST_ACTUAL_X="$POSE_X"
        LAST_ACTUAL_Y="$POSE_Y"
        break
      fi
      if (( attempt < GOAL_MAX_ATTEMPTS )); then
        log "retrying waypoint #$idx because the robot did not get close enough to the target"
        if [[ "$FORCE_STOP_BETWEEN_WAYPOINTS" == "1" ]]; then
          ros_publish_zero_cmd_vel || log "zero cmd_vel publish failed before retry (continuing)"
        fi
        sleep 1
      fi
    done
    if [[ "$goal_verified" != "1" ]]; then
      log "mission failed at waypoint #$idx: robot never got within ${GOAL_REACHED_MAX_ERROR_M}m of the target"
      exit 1
    fi
    PREVIOUS_PLANNED_X="$planned_x"
    PREVIOUS_PLANNED_Y="$planned_y"

    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY_RUN: sleep ${hold}s"
    else
      if [[ "$FORCE_STOP_BETWEEN_WAYPOINTS" == "1" ]]; then
        log "publishing zero cmd_vel before hold"
        ros_publish_zero_cmd_vel || log "zero cmd_vel publish failed (continuing)"
      fi
      sleep "$hold"
      if [[ "$CAPTURE_AT_WAYPOINT" == "1" ]]; then
        local min_capture_distance
        if ! read_robot_pose; then
          log "skipping still capture at waypoint #$idx because the current pose could not be queried"
          continue
        fi
        min_capture_distance="$(nearest_prior_capture_distance "$POSE_X" "$POSE_Y")"
        if [[ "$min_capture_distance" == "none" ]]; then
          log "pre-capture pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE nearest_prior_capture=none"
        else
          log "pre-capture pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE nearest_prior_capture=${min_capture_distance}m"
        fi
        if [[ "$min_capture_distance" != "none" ]] && ! float_gt "$min_capture_distance" "$CAPTURE_MIN_TRANSLATION_M"; then
          log "skipping still capture at waypoint #$idx because the robot only moved ${min_capture_distance}m since a prior saved capture"
          continue
        fi
        local img="${RUN_DIR}/raw/waypoint_$(printf '%03d' "$idx").jpg"
        log "capturing still image: $img"
        set +e
        capture_still_image "$img" >> "$LOG_FILE" 2>&1
        local c_rc=$?
        set -e
        if [[ "$c_rc" -ne 0 ]]; then
          log "still capture failed at waypoint #$idx (continuing)"
        else
          record_capture_pose "$idx" "$POSE_X" "$POSE_Y" "$POSE_YAW" "$POSE_SOURCE" "$img"
        fi
      fi
    fi
  done < "$WAYPOINT_FILE"

  log "mission complete"
}

main "$@"
