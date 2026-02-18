# RTAB-Map Setup + Raw Capture (Jetson, ROS 2 Humble in Docker)

Last updated: 2026-02-17

This project uses Ubuntu 20.04 on Jetson, so RTAB-Map is provisioned in a ROS 2 Humble Docker image.

## 1) Build image (one-time)
```bash
chmod +x scripts/*.sh
./scripts/build_rtabmap_image.sh
```

## 2) Start container
```bash
./scripts/run_rtabmap_container.sh
```

Inside container:
```bash
source /opt/ros/humble/setup.bash
```

## 3) Launch OAK camera driver (inside container)
```bash
./scripts/run_oak_camera.sh
```

Optional:
```bash
PARENT_FRAME=base_link NAME=oak ./scripts/run_oak_camera.sh
```

## 4) Validate camera/LiDAR topics
```bash
ros2 topic list
```

Expected minimum set:
- `/scan`
- `/odom`
- `/oak/rgb/image_raw`
- `/oak/rgb/camera_info`
- A depth topic (for RGB-D RTAB-Map), for example:
  - `/oak/stereo/image_raw` or
  - `/oak/depth/image_raw`

## 5) Capture raw bag
```bash
# Default topics are Create3 + RPLIDAR + OAK RGB.
# Add/override with TOPICS as needed.
RUN_NAME=$(date +%F)-lab_loop_a ./scripts/record_raw_bag.sh
```

Example with explicit depth topic included:
```bash
TOPICS="/tf /tf_static /odom /scan /oak/rgb/image_raw /oak/rgb/camera_info /oak/depth/image_raw" \
RUN_NAME=$(date +%F)-lab_loop_a \
./scripts/record_raw_bag.sh
```

## 6) Launch RTAB-Map
```bash
# Override DEPTH_TOPIC if your OAK driver publishes a different depth stream.
DEPTH_TOPIC=/oak/depth/image_raw ./scripts/run_rtabmap_rgbd.sh
```

## 7) Stop + verify artifacts
```bash
ls -lah runs/$(date +%F)-lab_loop_a/raw
```

## 8) Optional: add Nav2 pathfinding
See `TUTORIAL_nav2_with_rtabmap.md` for launching Nav2 with RTAB-Map localization and sending goals.
