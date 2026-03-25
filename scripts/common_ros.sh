#!/usr/bin/env bash

if [[ -n "${_GASSIAN_COMMON_ROS_SH:-}" ]]; then
  return 0
fi
_GASSIAN_COMMON_ROS_SH=1

readonly GASSIAN_DEFAULT_ROS_IMAGE="gassian/robot-runtime:latest"
readonly GASSIAN_COMPAT_ROS_IMAGE="gassian/ros2-humble-rtabmap:latest"
readonly GASSIAN_DEFAULT_ROS_CONTAINER="ros_humble_robot_runtime"
readonly GASSIAN_COMPAT_ROS_CONTAINER="ros_humble_rtabmap"
readonly GASSIAN_DEFAULT_RMW_IMPLEMENTATION="rmw_cyclonedds_cpp"
readonly GASSIAN_DEFAULT_ROS_DOMAIN_ID="0"
readonly GASSIAN_DEFAULT_ROS_LOCALHOST_ONLY="0"
readonly GASSIAN_DEFAULT_AUTONOMY_ROS_DOMAIN_ID="42"
readonly GASSIAN_DEFAULT_AUTONOMY_ROS_LOCALHOST_ONLY="0"
readonly GASSIAN_DEFAULT_PREFER_RUNNING_CONTAINER="1"
# Robot-side direct DDS diagnostics on this Jetson bind CycloneDDS to l4tbr0.
# The autonomy stack now defaults to a separate local-only graph on loopback.
readonly GASSIAN_DEFAULT_DDS_IFACE="l4tbr0"
readonly GASSIAN_DEFAULT_DDS_INCLUDE_LOOPBACK="0"
readonly GASSIAN_DEFAULT_AUTONOMY_DDS_IFACE="lo"
readonly GASSIAN_DEFAULT_AUTONOMY_DDS_INCLUDE_LOOPBACK="0"
readonly GASSIAN_DEFAULT_AUTONOMY_MAX_AUTO_PARTICIPANT_INDEX="120"
readonly GASSIAN_CREATE3_USB_RECOVERY_IFACE="l4tbr0"
readonly GASSIAN_CREATE3_USB_HOST_CIDR="192.168.186.3/24"
readonly GASSIAN_CREATE3_USB_RUNTIME_START="/opt/nvidia/l4t-usb-device-mode/nv-l4t-usb-device-mode-runtime-start.sh"

readonly GASSIAN_DEFAULT_TF_TOPIC="/tf"
readonly GASSIAN_DEFAULT_TF_STATIC_TOPIC="/tf_static"
readonly GASSIAN_DEFAULT_ODOM_TOPIC="/odom"
readonly GASSIAN_DEFAULT_SCAN_TOPIC="/scan"
readonly GASSIAN_DEFAULT_RGB_TOPIC="/oak/rgb/image_raw"
readonly GASSIAN_DEFAULT_CAMERA_INFO_TOPIC="/oak/rgb/camera_info"
readonly GASSIAN_DEFAULT_DEPTH_TOPIC="/oak/stereo/image_raw"
readonly GASSIAN_ALT_DEPTH_TOPIC="/oak/depth/image_raw"
readonly GASSIAN_DEFAULT_DEPTH_CAMERA_INFO_TOPIC="/oak/stereo/camera_info"
readonly GASSIAN_ALT_DEPTH_CAMERA_INFO_TOPIC="/oak/depth/camera_info"
readonly GASSIAN_DEFAULT_RTABMAP_FRAME_ID="base_link"
readonly GASSIAN_DEFAULT_RTABMAP_VIZ="false"
readonly GASSIAN_DEFAULT_RVIZ="false"
readonly GASSIAN_DEFAULT_VISUAL_ODOMETRY="false"
readonly GASSIAN_DEFAULT_RTABMAP_ARGS="--delete_db_on_start"
# rtabmap_launch uses numeric QoS enums; 2 is the best-effort sensor-data setting we verified with OAK.
readonly GASSIAN_DEFAULT_RTABMAP_QOS="2"
readonly GASSIAN_DEFAULT_RTABMAP_APPROX_SYNC="true"
readonly GASSIAN_DEFAULT_RTABMAP_TOPIC_QUEUE_SIZE="30"
readonly GASSIAN_DEFAULT_RTABMAP_SYNC_QUEUE_SIZE="30"
readonly GASSIAN_DEFAULT_RTABMAP_APPROX_SYNC_MAX_INTERVAL="0.02"
readonly GASSIAN_FALLBACK_STEREO_RTABMAP_TOPIC_QUEUE_SIZE="40"
readonly GASSIAN_FALLBACK_STEREO_RTABMAP_SYNC_QUEUE_SIZE="40"
readonly GASSIAN_FALLBACK_STEREO_RTABMAP_APPROX_SYNC_MAX_INTERVAL="0.04"

build_cyclonedds_uri() {
  local iface="$1"
  local include_loopback="${2:-1}"

  if [[ "$include_loopback" == "1" ]]; then
    printf '<CycloneDDS><Domain><General><Interfaces><NetworkInterface name="lo" multicast="default" /><NetworkInterface name="%s" multicast="default" /></Interfaces><DontRoute>true</DontRoute></General></Domain></CycloneDDS>' "$iface"
    return 0
  fi

  printf '<CycloneDDS><Domain><General><NetworkInterfaceAddress>%s</NetworkInterfaceAddress><DontRoute>true</DontRoute></General></Domain></CycloneDDS>' "$iface"
}

build_local_autonomy_cyclonedds_uri() {
  local iface="${1:-$GASSIAN_DEFAULT_AUTONOMY_DDS_IFACE}"
  local max_auto_index="${2:-$GASSIAN_DEFAULT_AUTONOMY_MAX_AUTO_PARTICIPANT_INDEX}"

  printf '<CycloneDDS><Domain><General><NetworkInterfaceAddress>%s</NetworkInterfaceAddress><DontRoute>true</DontRoute></General><Discovery><ParticipantIndex>auto</ParticipantIndex><MaxAutoParticipantIndex>%s</MaxAutoParticipantIndex></Discovery></Domain></CycloneDDS>' \
    "$iface" \
    "$max_auto_index"
}

apply_create3_oak_defaults() {
  export ROS_IMAGE="${ROS_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}"
  export ROS_CONTAINER="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"
  export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-$GASSIAN_DEFAULT_RMW_IMPLEMENTATION}"
  export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_ROS_DOMAIN_ID}"
  export ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-$GASSIAN_DEFAULT_ROS_LOCALHOST_ONLY}"
  export DDS_IFACE="${DDS_IFACE:-$GASSIAN_DEFAULT_DDS_IFACE}"
  export DDS_INCLUDE_LOOPBACK="${DDS_INCLUDE_LOOPBACK:-$GASSIAN_DEFAULT_DDS_INCLUDE_LOOPBACK}"

  if [[ "$RMW_IMPLEMENTATION" == "rmw_cyclonedds_cpp" && -z "${CYCLONEDDS_URI:-}" && -n "$DDS_IFACE" ]]; then
    export CYCLONEDDS_URI
    CYCLONEDDS_URI="$(build_cyclonedds_uri "$DDS_IFACE" "$DDS_INCLUDE_LOOPBACK")"
  fi
}

apply_autonomy_local_defaults() {
  export ROS_IMAGE="${ROS_IMAGE:-$GASSIAN_DEFAULT_ROS_IMAGE}"
  export ROS_CONTAINER="${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}"
  export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-$GASSIAN_DEFAULT_RMW_IMPLEMENTATION}"
  export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$GASSIAN_DEFAULT_AUTONOMY_ROS_DOMAIN_ID}"
  export ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-$GASSIAN_DEFAULT_AUTONOMY_ROS_LOCALHOST_ONLY}"
  export DDS_IFACE="${DDS_IFACE:-$GASSIAN_DEFAULT_AUTONOMY_DDS_IFACE}"
  export DDS_INCLUDE_LOOPBACK="${DDS_INCLUDE_LOOPBACK:-$GASSIAN_DEFAULT_AUTONOMY_DDS_INCLUDE_LOOPBACK}"

  if [[ "$RMW_IMPLEMENTATION" == "rmw_cyclonedds_cpp" && -z "${CYCLONEDDS_URI:-}" && -n "$DDS_IFACE" ]]; then
    export CYCLONEDDS_URI
    CYCLONEDDS_URI="$(build_local_autonomy_cyclonedds_uri "$DDS_IFACE")"
  fi
}

ensure_dds_iface_exists() {
  local iface="${1:-${DDS_IFACE:-}}"

  if [[ -z "$iface" ]]; then
    return 0
  fi

  if ! command -v ip >/dev/null 2>&1; then
    echo "Missing required command: ip" >&2
    return 1
  fi

  if ! ip link show "$iface" >/dev/null 2>&1; then
    echo "DDS interface not found: $iface" >&2
    echo "Set DDS_IFACE=<iface> if needed." >&2
    return 1
  fi
}

dds_iface_has_ipv4_cidr() {
  local iface="$1"
  local expected_cidr="$2"

  ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | grep -Fxq "$expected_cidr"
}

ensure_create3_usb_host_iface() {
  local iface="${1:-$GASSIAN_DEFAULT_DDS_IFACE}"
  local expected_cidr="${2:-$GASSIAN_CREATE3_USB_HOST_CIDR}"
  local recovery_script="${3:-$GASSIAN_CREATE3_USB_RUNTIME_START}"

  ensure_dds_iface_exists "$iface" || return 1

  if [[ "$iface" != "$GASSIAN_CREATE3_USB_RECOVERY_IFACE" ]]; then
    return 0
  fi

  if dds_iface_has_ipv4_cidr "$iface" "$expected_cidr"; then
    return 0
  fi

  if [[ ! -x "$recovery_script" ]]; then
    echo "Create3 USB recovery helper is missing or not executable: $recovery_script" >&2
    return 1
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Missing required command: sudo" >&2
    return 1
  fi

  echo "Restoring ${iface} host address via ${recovery_script}..." >&2
  if ! sudo -n "$recovery_script" >/dev/null 2>&1; then
    echo "Failed to run ${recovery_script} with sudo -n." >&2
    return 1
  fi

  if ! dds_iface_has_ipv4_cidr "$iface" "$expected_cidr"; then
    echo "Expected ${iface} to have ${expected_cidr} after recovery, but it does not." >&2
    return 1
  fi
}

normalize_frame_id() {
  local frame_id="${1:-}"

  while [[ "$frame_id" == /* ]]; do
    frame_id="${frame_id#/}"
  done

  printf "%s" "$frame_id"
}

derive_camera_info_topic_from_image_topic() {
  local image_topic="$1"

  case "$image_topic" in
    */image_raw|*/image_rect)
      printf "%s/camera_info" "${image_topic%/*}"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_rgb_camera_info_topic() {
  local rgb_topic="$1"
  local default_topic="${2:-$GASSIAN_DEFAULT_CAMERA_INFO_TOPIC}"
  local derived_topic

  if derived_topic="$(derive_camera_info_topic_from_image_topic "$rgb_topic" 2>/dev/null)"; then
    printf "%s" "$derived_topic"
    return 0
  fi

  printf "%s" "$default_topic"
}

ros_container_is_running() {
  local container_name="${1:-${ROS_CONTAINER:-$GASSIAN_DEFAULT_ROS_CONTAINER}}"

  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container_name"
}
