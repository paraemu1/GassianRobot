#!/usr/bin/env bash
set -euo pipefail

# Local stop-go scan mission using Nav2 behavior actions instead of NavigateToPose.
# Reads waypoints TSV: x y qz qw hold_sec

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./common_ros.sh
source "${SCRIPT_DIR}/common_ros.sh"

WAYPOINT_FILE="${WAYPOINT_FILE:-${REPO_ROOT}/config/scan_waypoints_room_a_conservative.tsv}"
RUN_NAME="${RUN_NAME:-$(date +%F)-auto-room-scan}"
RUN_DIR="${REPO_ROOT}/runs/${RUN_NAME}"
DRY_RUN="${DRY_RUN:-0}"
CAPTURE_AT_WAYPOINT="${CAPTURE_AT_WAYPOINT:-1}"
CAPTURE_WIDTH="${CAPTURE_WIDTH:-1280}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-720}"
MIN_HOLD_SEC="${MIN_HOLD_SEC:-0}"
FORCE_STOP_BETWEEN_WAYPOINTS="${FORCE_STOP_BETWEEN_WAYPOINTS:-1}"
REQUIRE_DDS_IFACE="${REQUIRE_DDS_IFACE:-1}"
POSE_QUERY_TIMEOUT_SEC="${POSE_QUERY_TIMEOUT_SEC:-5}"
CAPTURE_MIN_TRANSLATION_M="${CAPTURE_MIN_TRANSLATION_M:-0.10}"
DRIVE_SPEED_MPS="${DRIVE_SPEED_MPS:-0.05}"
SEGMENT_MIN_TRANSLATION_M="${SEGMENT_MIN_TRANSLATION_M:-0.10}"
DRIVE_TIME_ALLOWANCE_SEC_PER_M="${DRIVE_TIME_ALLOWANCE_SEC_PER_M:-40}"
SPIN_MIN_ANGLE_RAD="${SPIN_MIN_ANGLE_RAD:-0.05}"
SPIN_TIME_ALLOWANCE_SEC="${SPIN_TIME_ALLOWANCE_SEC:-15}"
SPIN_ACTION_NAME="${SPIN_ACTION_NAME:-/spin}"
DRIVE_ON_HEADING_ACTION_NAME="${DRIVE_ON_HEADING_ACTION_NAME:-/drive_on_heading}"
BOUNDARY_PARTIAL_TRANSLATION_M="${BOUNDARY_PARTIAL_TRANSLATION_M:-0.05}"
RETURN_TO_ENTRY_AFTER_SURVEY="${RETURN_TO_ENTRY_AFTER_SURVEY:-1}"
BACKTRACK_SEGMENT_SETTLE_SEC="${BACKTRACK_SEGMENT_SETTLE_SEC:-1}"
BOUNDARY_ON_CREATE3_STOP="${BOUNDARY_ON_CREATE3_STOP:-1}"
BOUNDARY_ON_DRIVE_ABORT="${BOUNDARY_ON_DRIVE_ABORT:-1}"

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

segment_distance_and_heading() {
  local x1="$1" y1="$2" x2="$3" y2="$4"

  awk -v x1="$x1" -v y1="$y1" -v x2="$x2" -v y2="$y2" 'BEGIN {
    dx = (x2 + 0.0) - (x1 + 0.0)
    dy = (y2 + 0.0) - (y1 + 0.0)
    printf "%.6f %.6f", sqrt(dx * dx + dy * dy), atan2(dy, dx)
  }'
}

normalize_angle() {
  local angle="$1"

  awk -v angle="$angle" 'BEGIN {
    pi = atan2(0, -1)
    while (angle > pi) {
      angle -= 2 * pi
    }
    while (angle < -pi) {
      angle += 2 * pi
    }
    printf "%.6f", angle
  }'
}

absolute_value() {
  local value="$1"

  awk -v value="$value" 'BEGIN {
    if ((value + 0.0) < 0.0) {
      value = -value
    }
    printf "%.6f", value + 0.0
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
      "source /opt/ros/humble/setup.bash && cd '${CONTAINER_WORKDIR:-/robot_ws}' && python3 ./scripts/get_robot_map_pose.py --timeout-sec '$POSE_QUERY_TIMEOUT_SEC'"
    return
  fi

  if command -v ros2 >/dev/null 2>&1; then
    python3 "${REPO_ROOT}/scripts/get_robot_map_pose.py" --timeout-sec "$POSE_QUERY_TIMEOUT_SEC"
    return
  fi

  docker run --rm --network host \
    -v "${REPO_ROOT}:${CONTAINER_WORKDIR:-/robot_ws}" \
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_AUTONOMY_ROS_DOMAIN_ID}" \
    -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
    -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
    "$ROS_IMAGE" bash -lc \
      "source /opt/ros/humble/setup.bash && cd '${CONTAINER_WORKDIR:-/robot_ws}' && python3 ./scripts/get_robot_map_pose.py --timeout-sec '$POSE_QUERY_TIMEOUT_SEC'"
}

POSE_X=""
POSE_Y=""
POSE_YAW=""
POSE_SOURCE=""
LAST_DRIVE_DISTANCE_TRAVELED="0"
LAST_MOTION_READY_RC="0"
LAST_MOTION_READY_OUTPUT=""
declare -a EXECUTED_SEGMENT_HEADINGS=()
declare -a EXECUTED_SEGMENT_DISTANCES=()

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

extract_last_distance_traveled() {
  printf '%s\n' "$1" | awk '
    /distance_traveled:/ {
      value = $2
    }
    END {
      if (value == "") {
        value = "0"
      }
      printf "%s", value
    }'
}

record_executed_segment() {
  local heading="$1" distance="$2"

  EXECUTED_SEGMENT_HEADINGS+=("$heading")
  EXECUTED_SEGMENT_DISTANCES+=("$distance")
}

check_create3_motion_ready() {
  local out rc

  set +e
  out="$(bash "${REPO_ROOT}/scripts/create3_motion_ready_check.sh" 2>&1)"
  rc=$?
  set -e

  LAST_MOTION_READY_RC="$rc"
  LAST_MOTION_READY_OUTPUT="$out"
  echo "$out" >> "$LOG_FILE"
  return "$rc"
}

motion_stop_is_boundary() {
  local rc="$1"

  [[ "$rc" == "10" || "$rc" == "11" || "$rc" == "12" ]]
}

complete_boundary_limited_mission() {
  local idx="$1" segment_heading="$2" record_current_segment="${3:-1}"

  if [[ "$record_current_segment" == "1" ]] && float_gt "$LAST_DRIVE_DISTANCE_TRAVELED" "0.001"; then
    record_executed_segment "$segment_heading" "$LAST_DRIVE_DISTANCE_TRAVELED"
  fi

  if (( ${#EXECUTED_SEGMENT_DISTANCES[@]} == 0 )); then
    log "boundary/ledge encountered immediately at segment #${idx}; no completed survey segments to backtrack"
    return 1
  fi

  log "treating segment #${idx} as a boundary hit and backtracking"
  if backtrack_executed_segments; then
    log "mission complete (boundary-limited)"
    return 0
  fi

  log "mission failed while backtracking after segment #${idx}"
  return 1
}

ros_send_action() {
  local action_name="$1" action_type="$2" payload="$3"

  if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
    docker exec "$ROS_CONTAINER" bash -lc \
      "source /opt/ros/humble/setup.bash && ros2 action send_goal '$action_name' '$action_type' '$payload' --feedback"
    return
  fi

  if command -v ros2 >/dev/null 2>&1; then
    ros2 action send_goal "$action_name" "$action_type" "$payload" --feedback
    return
  fi

  docker run --rm --network host \
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_AUTONOMY_ROS_DOMAIN_ID}" \
    -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
    -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
    "$ROS_IMAGE" bash -lc \
      "source /opt/ros/humble/setup.bash && ros2 action send_goal '$action_name' '$action_type' '$payload' --feedback"
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
    docker exec "$ROS_CONTAINER" bash -lc \
      "source /opt/ros/humble/setup.bash && cd '${CONTAINER_WORKDIR:-/robot_ws}' && python3 ./scripts/capture_oak_still.py --output '$output_container' --width '$CAPTURE_WIDTH' --height '$CAPTURE_HEIGHT'"
    return
  fi

  python3 "${REPO_ROOT}/scripts/capture_oak_still.py" \
    --output "$output_host" --width "$CAPTURE_WIDTH" --height "$CAPTURE_HEIGHT"
}

send_spin_wait() {
  local angle="$1"
  local payload
  local angle_abs

  angle_abs="$(absolute_value "$angle")"
  if ! float_gt "$angle_abs" "$SPIN_MIN_ANGLE_RAD"; then
    log "spin skipped: |${angle}|rad <= ${SPIN_MIN_ANGLE_RAD}rad"
    return 0
  fi

  payload="{target_yaw: $angle, time_allowance: {sec: $SPIN_TIME_ALLOWANCE_SEC, nanosec: 0}}"
  log "spin -> delta_yaw=${angle}rad"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: ros_send_action $SPIN_ACTION_NAME nav2_msgs/action/Spin ..."
    return 0
  fi

  local out rc
  set +e
  out="$(ros_send_action "$SPIN_ACTION_NAME" nav2_msgs/action/Spin "$payload" 2>&1)"
  rc=$?
  set -e
  echo "$out" >> "$LOG_FILE"

  if [[ "$rc" -ne 0 ]]; then
    log "spin action failed, rc=$rc"
    return 1
  fi

  if echo "$out" | grep -Eqi "aborted|rejected|canceled|failed"; then
    log "spin failed per action output"
    return 1
  fi

  log "spin action completed"
  return 0
}

drive_segment_wait() {
  local distance="$1"
  local payload
  local time_allowance_sec
  LAST_DRIVE_DISTANCE_TRAVELED="0"

  time_allowance_sec="$(awk -v distance="$distance" -v sec_per_m="$DRIVE_TIME_ALLOWANCE_SEC_PER_M" 'BEGIN {
    value = int((distance + 0.0) * (sec_per_m + 0.0) + 5.0)
    if (value < 5) {
      value = 5
    }
    printf "%d", value
  }')"
  payload="{target: {x: $distance, y: 0.0, z: 0.0}, speed: $DRIVE_SPEED_MPS, time_allowance: {sec: $time_allowance_sec, nanosec: 0}}"
  log "drive_on_heading -> distance=${distance}m speed=${DRIVE_SPEED_MPS}m/s"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: ros_send_action $DRIVE_ON_HEADING_ACTION_NAME nav2_msgs/action/DriveOnHeading ..."
    return 0
  fi

  local out rc
  set +e
  out="$(ros_send_action "$DRIVE_ON_HEADING_ACTION_NAME" nav2_msgs/action/DriveOnHeading "$payload" 2>&1)"
  rc=$?
  set -e
  echo "$out" >> "$LOG_FILE"
  LAST_DRIVE_DISTANCE_TRAVELED="$(extract_last_distance_traveled "$out")"

  if [[ "$rc" -ne 0 ]]; then
    log "drive_on_heading action failed, rc=$rc distance_traveled=${LAST_DRIVE_DISTANCE_TRAVELED}m"
    return 1
  fi

  if echo "$out" | grep -Eqi "aborted|rejected|canceled|failed"; then
    log "drive_on_heading failed per action output distance_traveled=${LAST_DRIVE_DISTANCE_TRAVELED}m"
    return 1
  fi

  log "drive_on_heading action completed"
  return 0
}

backtrack_executed_segments() {
  local count="${#EXECUTED_SEGMENT_DISTANCES[@]}"
  local i reverse_heading spin_delta current_yaw

  if (( count == 0 )); then
    log "no executed segments available to backtrack"
    return 0
  fi

  log "backtracking ${count} executed segments toward entry"
  for ((i = count - 1; i >= 0; i--)); do
    read_robot_pose || return 1
    current_yaw="$POSE_YAW"
    reverse_heading="$(normalize_angle "$(awk -v heading="${EXECUTED_SEGMENT_HEADINGS[$i]}" 'BEGIN { printf "%.6f", (heading + 0.0) + atan2(0, -1) }')")"
    spin_delta="$(normalize_angle "$(awk -v target="$reverse_heading" -v current="$current_yaw" 'BEGIN { printf "%.6f", (target + 0.0) - (current + 0.0) }')")"
    log "backtrack segment $((i + 1))/${count}: reverse_heading=${reverse_heading}rad distance=${EXECUTED_SEGMENT_DISTANCES[$i]}m"
    send_spin_wait "$spin_delta" || return 1
    drive_segment_wait "${EXECUTED_SEGMENT_DISTANCES[$i]}" || return 1
    ros_publish_zero_cmd_vel || true
    if [[ "$BACKTRACK_SEGMENT_SETTLE_SEC" != "0" ]]; then
      sleep "$BACKTRACK_SEGMENT_SETTLE_SEC"
    fi
  done

  return 0
}

main() {
  : > "$LOG_FILE"
  log "starting local stop-go scan mission"
  log "run_dir=$RUN_DIR"
  log "waypoints=$WAYPOINT_FILE"
  log "dry_run=$DRY_RUN"
  log "min_hold_sec=$MIN_HOLD_SEC"
  log "capture_min_translation_m=$CAPTURE_MIN_TRANSLATION_M"
  log "drive_speed_mps=$DRIVE_SPEED_MPS"
  log "segment_min_translation_m=$SEGMENT_MIN_TRANSLATION_M"
  log "boundary_partial_translation_m=$BOUNDARY_PARTIAL_TRANSLATION_M"
  log "boundary_on_create3_stop=$BOUNDARY_ON_CREATE3_STOP"
  log "boundary_on_drive_abort=$BOUNDARY_ON_DRIVE_ABORT"
  log "return_to_entry_after_survey=$RETURN_TO_ENTRY_AFTER_SURVEY"
  log "spin_min_angle_rad=$SPIN_MIN_ANGLE_RAD"
  log "spin_action_name=$SPIN_ACTION_NAME"
  log "drive_on_heading_action_name=$DRIVE_ON_HEADING_ACTION_NAME"

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

  read_robot_pose || { log "failed to read starting pose"; exit 1; }
  local previous_planned_x="$POSE_X"
  local previous_planned_y="$POSE_Y"
  log "starting pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE"

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

    local segment_distance segment_heading
    read -r segment_distance segment_heading <<< "$(segment_distance_and_heading "$previous_planned_x" "$previous_planned_y" "$x" "$y")"

    local start_x="$POSE_X" start_y="$POSE_Y" current_yaw="$POSE_YAW"
    if [[ "$DRY_RUN" != "1" ]]; then
      read_robot_pose || { log "failed to read pose before segment #$idx"; exit 1; }
      start_x="$POSE_X"
      start_y="$POSE_Y"
      current_yaw="$POSE_YAW"
    fi

    local spin_delta
    spin_delta="$(normalize_angle "$(awk -v target="$segment_heading" -v current="$current_yaw" 'BEGIN {printf "%.6f", (target + 0.0) - (current + 0.0)}')")"
    log "segment #$idx: planned_target=$x,$y distance=${segment_distance}m heading=${segment_heading}rad spin_delta=${spin_delta}rad hold=${hold}s qz=$qz qw=$qw"

    if ! send_spin_wait "$spin_delta"; then
      log "mission failed at segment #$idx during spin"
      exit 1
    fi

    if ! drive_segment_wait "$segment_distance"; then
      local drive_failed_due_to_robot_stop=0
      log "segment #$idx drive failed after ${LAST_DRIVE_DISTANCE_TRAVELED}m"
      if [[ "$BOUNDARY_ON_CREATE3_STOP" == "1" ]] && [[ "$DRY_RUN" != "1" ]]; then
        if ! check_create3_motion_ready; then
          if motion_stop_is_boundary "$LAST_MOTION_READY_RC"; then
            drive_failed_due_to_robot_stop=1
            log "segment #$idx drive abort matches a live Create3 stop boundary"
          fi
        fi
      fi
      if [[ "$BOUNDARY_ON_DRIVE_ABORT" == "1" ]] || float_gt "$LAST_DRIVE_DISTANCE_TRAVELED" "$BOUNDARY_PARTIAL_TRANSLATION_M" || [[ "$drive_failed_due_to_robot_stop" == "1" ]]; then
        if complete_boundary_limited_mission "$idx" "$segment_heading" 1; then
          return 0
        fi
      fi
      log "mission failed at segment #$idx during drive"
      exit 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY_RUN: sleep ${hold}s"
    else
      read_robot_pose || { log "failed to read pose after segment #$idx"; exit 1; }
      local actual_translation
      actual_translation="$(distance_between_points "$start_x" "$start_y" "$POSE_X" "$POSE_Y")"
      log "post-segment pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE actual_translation=${actual_translation}m drive_feedback=${LAST_DRIVE_DISTANCE_TRAVELED}m"
      if float_gt "$SEGMENT_MIN_TRANSLATION_M" "$LAST_DRIVE_DISTANCE_TRAVELED"; then
        log "mission failed at segment #$idx: robot only moved ${LAST_DRIVE_DISTANCE_TRAVELED}m"
        exit 1
      fi
      record_executed_segment "$segment_heading" "$LAST_DRIVE_DISTANCE_TRAVELED"

      if [[ "$BOUNDARY_ON_CREATE3_STOP" == "1" ]]; then
        if ! check_create3_motion_ready; then
          if motion_stop_is_boundary "$LAST_MOTION_READY_RC"; then
            log "segment #$idx ended at a live Create3 stop boundary"
            if complete_boundary_limited_mission "$idx" "$segment_heading" 0; then
              return 0
            fi
          fi
          log "mission failed after segment #$idx because Create3 is no longer motion-ready"
          exit 1
        fi
      fi

      if [[ "$FORCE_STOP_BETWEEN_WAYPOINTS" == "1" ]]; then
        log "publishing zero cmd_vel before hold"
        ros_publish_zero_cmd_vel || log "zero cmd_vel publish failed (continuing)"
      fi

      sleep "$hold"
      if [[ "$CAPTURE_AT_WAYPOINT" == "1" ]]; then
        local min_capture_distance
        if ! read_robot_pose; then
          log "skipping still capture at segment #$idx because the current pose could not be queried"
          previous_planned_x="$x"
          previous_planned_y="$y"
          continue
        fi
        min_capture_distance="$(nearest_prior_capture_distance "$POSE_X" "$POSE_Y")"
        if [[ "$min_capture_distance" == "none" ]]; then
          log "pre-capture pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE nearest_prior_capture=none"
        else
          log "pre-capture pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE nearest_prior_capture=${min_capture_distance}m"
        fi
        if [[ "$min_capture_distance" != "none" ]] && ! float_gt "$min_capture_distance" "$CAPTURE_MIN_TRANSLATION_M"; then
          log "skipping still capture at segment #$idx because the robot only moved ${min_capture_distance}m since a prior saved capture"
        else
          local img="${RUN_DIR}/raw/waypoint_$(printf '%03d' "$idx").jpg"
          log "capturing still image: $img"
          set +e
          capture_still_image "$img" >> "$LOG_FILE" 2>&1
          local c_rc=$?
          set -e
          if [[ "$c_rc" -ne 0 ]]; then
            log "still capture failed at segment #$idx (continuing)"
          else
            record_capture_pose "$idx" "$POSE_X" "$POSE_Y" "$POSE_YAW" "$POSE_SOURCE" "$img"
          fi
        fi
      fi
    fi

    previous_planned_x="$x"
    previous_planned_y="$y"
  done < "$WAYPOINT_FILE"

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$RETURN_TO_ENTRY_AFTER_SURVEY" == "1" ]]; then
      log "DRY_RUN: return-to-entry backtrack is enabled for live runs"
    fi
  elif [[ "$RETURN_TO_ENTRY_AFTER_SURVEY" == "1" ]]; then
    log "survey complete; backtracking to entry before closeout"
    if ! backtrack_executed_segments; then
      log "mission failed while returning to entry after survey"
      exit 1
    fi
    read_robot_pose || { log "failed to read pose after return-to-entry backtrack"; exit 1; }
    log "post-backtrack pose: x=$POSE_X y=$POSE_Y yaw=$POSE_YAW source=$POSE_SOURCE"
  fi

  log "mission complete"
}

main "$@"
