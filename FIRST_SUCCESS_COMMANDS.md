# First Successful Run: Copy-Paste Commands

Use these from the Jetson shell.
System-level notes from this setup session: `SYSTEM_STATE_2026-02-17.md`

## Create 3 bringup and safety motion check (verified 2026-02-17)

### 0) Confirm robot firmware and ROS distro
```bash
curl --interface l4tbr0 -sS http://192.168.186.2/home | \
  grep -o 'version="[^"]*"\|rosversionname="[^"]*"'
```

Expected after update in this project:
- `version="H.2.6"`
- `rosversionname="Humble"`

### 1) Ensure Create 3 ROS config (domain/RMW)
```bash
curl --interface l4tbr0 -sS -X POST http://192.168.186.2/ros-config-save-main \
  --data-urlencode 'ros_domain_id=0' \
  --data-urlencode 'ros_namespace=' \
  --data-urlencode 'rmw_implementation=rmw_cyclonedds_cpp' \
  --data-urlencode 'fast_discovery_server_enabled=false' \
  --data-urlencode 'fast_discovery_server_value='

curl --interface l4tbr0 -sS -X POST http://192.168.186.2/api/restart-app
```

### 2) Tiny safe rotate test (table-safe)
This sends a very small angular command and immediate stop.
```bash
docker run --rm --network host ros:humble-ros-base bash -lc '
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
export CYCLONEDDS_URI="<CycloneDDS><Domain><General><NetworkInterfaceAddress>l4tbr0</NetworkInterfaceAddress><DontRoute>true</DontRoute></General></Domain></CycloneDDS>"

ros2 topic info /cmd_vel
ros2 topic pub --once --wait-matching-subscriptions 1 /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.08}}"
sleep 0.25
ros2 topic pub --once --wait-matching-subscriptions 1 /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}"
'
```

### 3) Numeric confirmation via odometry delta
In this session, a test produced approximately `+7.33°` yaw change with near-zero translation:
- `dyaw_rad: 0.1279`
- `dyaw_deg: 7.3287`
- `dx: 0.00051 m`
- `dy: -0.00056 m`

## 1) Make scripts executable
```bash
chmod +x scripts/*.sh
```

## 2) Build container images (one-time or after updates)
```bash
./scripts/build_rtabmap_image.sh
./scripts/build_training_image.sh
```

## 3) Start with a run folder
```bash
./scripts/init_run_dir.sh lab_loop_a
```

## 4) ROS topic health check
```bash
# Optionally override topic names for your launch setup:
# TOPIC_IMAGE=/camera/color/image_raw TOPIC_CAMERA_INFO=/camera/color/camera_info ./scripts/ros_health_check.sh
./scripts/ros_health_check.sh
```

## 5) Start the RTAB-Map container
```bash
./scripts/run_rtabmap_container.sh
```

Inside the container:
```bash
source /opt/ros/humble/setup.bash
```

## 6) Launch the OAK camera driver (inside container)
```bash
./scripts/run_oak_camera.sh
```

Optional overrides:
```bash
PARENT_FRAME=base_link NAME=oak ./scripts/run_oak_camera.sh
```

## 7) Record a short raw bag (30-60 seconds)
```bash
# Override TOPICS if your camera driver uses different names.
RUN_NAME=$(date +%F)-lab_loop_a ./scripts/record_raw_bag.sh
```

## 8) Launch RTAB-Map (RGB-D, optional mapping/localization pass)
```bash
# If your depth topic differs, override DEPTH_TOPIC.
./scripts/run_rtabmap_rgbd.sh
```

## 9) Launch Nav2 (pathfinding/navigation)
```bash
# Run in another shell while RTAB-Map is running.
./scripts/run_nav2_with_rtabmap.sh
```

## 10) Send a Nav2 goal
```bash
# Example goal in map frame: x=1.0, y=0.0, facing forward.
./scripts/send_nav2_goal.sh 1.0 0.0 0.0 1.0
```

## Safety gate (table/fall risk)
```bash
# Planning-only test (no drive command) while robot is elevated:
ros2 action send_goal /compute_path_to_pose nav2_msgs/action/ComputePathToPose \
"{goal:{header:{frame_id:map},pose:{position:{x:1.0,y:0.0,z:0.0},orientation:{z:0.0,w:1.0}}},use_start:false}"
```

## 11) Save a short RGB video to the run (for Gaussian training input)
```bash
# Example capture command; replace /dev/video0 if needed.
ffmpeg -y -f v4l2 -framerate 30 -video_size 1280x720 \
  -i /dev/video0 \
  runs/$(date +%F)-lab_loop_a/raw/capture.mp4
```

## 12) Prepare run input manifest (binds run -> video)
```bash
./scripts/prepare_gs_input_from_run.sh --run runs/$(date +%F)-lab_loop_a
```

## 13) Process -> Train -> Export in Docker (default)
```bash
./scripts/process_train_export.sh \
  --run runs/$(date +%F)-lab_loop_a \
  --from-run-env \
  --downscale 2
```

Optional debug shell in training image:
```bash
./scripts/run_training_container.sh
```

## 14) Artifacts to verify
```bash
ls -lah runs/$(date +%F)-lab_loop_a/dataset
ls -lah runs/$(date +%F)-lab_loop_a/checkpoints
ls -lah runs/$(date +%F)-lab_loop_a/exports/splat
ls -lah runs/$(date +%F)-lab_loop_a/raw
```
