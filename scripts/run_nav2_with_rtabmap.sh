#!/usr/bin/env bash
set -euo pipefail

# Launch Nav2 navigation stack while localization/map come from RTAB-Map.
# Expected: RTAB-Map is already publishing map->odom TF and /map.

NAMESPACE="${NAMESPACE:-}"
USE_SIM_TIME="${USE_SIM_TIME:-false}"
AUTOSTART="${AUTOSTART:-true}"
PARAMS_FILE="${PARAMS_FILE:-/opt/ros/humble/share/nav2_bringup/params/nav2_params.yaml}"
USE_COMPOSITION="${USE_COMPOSITION:-false}"
USE_RESPAWN="${USE_RESPAWN:-false}"
LOG_LEVEL="${LOG_LEVEL:-info}"

if ! command -v ros2 >/dev/null 2>&1; then
  echo "Missing required command: ros2" >&2
  exit 1
fi

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "Nav2 params file not found: $PARAMS_FILE" >&2
  exit 1
fi

normalize_bool() {
  case "${1,,}" in
    true|1|yes|on) echo "True" ;;
    false|0|no|off) echo "False" ;;
    *)
      echo "Invalid boolean value: $1" >&2
      exit 1
      ;;
  esac
}

USE_SIM_TIME="$(normalize_bool "$USE_SIM_TIME")"
AUTOSTART="$(normalize_bool "$AUTOSTART")"
USE_COMPOSITION="$(normalize_bool "$USE_COMPOSITION")"
USE_RESPAWN="$(normalize_bool "$USE_RESPAWN")"

launch_args=(
  "use_sim_time:=$USE_SIM_TIME"
  "params_file:=$PARAMS_FILE"
  "autostart:=$AUTOSTART"
  "use_composition:=$USE_COMPOSITION"
  "use_respawn:=$USE_RESPAWN"
  "log_level:=$LOG_LEVEL"
)

if [[ -n "$NAMESPACE" ]]; then
  launch_args+=("namespace:=$NAMESPACE")
fi

if command -v ros2 >/dev/null 2>&1; then
  ros2 launch nav2_bringup navigation_launch.py "${launch_args[@]}"
  exit $?
fi

if docker ps --format '{{.Names}}' | grep -Fxq "$ROS_CONTAINER"; then
  docker exec -it "$ROS_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && ros2 launch nav2_bringup navigation_launch.py ${launch_args[*]}"
  exit $?
fi

docker run --rm -it --network host --ipc host \
  -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}" \
  -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}" \
  -e ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}" \
  -e CYCLONEDDS_URI="${CYCLONEDDS_URI:-}" \
  "$ROS_IMAGE" bash -lc "source /opt/ros/humble/setup.bash && ros2 launch nav2_bringup navigation_launch.py ${launch_args[*]}"
