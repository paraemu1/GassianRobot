# RTAB-Map Setup + Raw Capture (Jetson, unified robot runtime container)

Last updated: 2026-03-25

This project uses a unified robot runtime Docker image for live robot work, but the live autonomy path is now split across two DDS graphs so OAK + RTAB-Map traffic does not saturate the Create 3 USB DDS link.

## Bringup architecture

The current live stack is:

- Host shell starts `./scripts/robot/run_robot_runtime_container.sh`
- Unified runtime container `ros_humble_robot_runtime` defaults to a local-only autonomy graph:
  - `ROS_DOMAIN_ID=42`
  - `DDS_IFACE=lo`
- `./scripts/robot/run_oak_camera.sh` launches `depthai_ros_driver` with `config/oak_rgbd_sync.yaml` so RGB and stereo are published in sync
- `./scripts/robot/run_rtabmap_rgbd.sh` now defaults to the validated wheel-odom-assisted path on this Jetson/robot setup
- `./scripts/robot/run_create3_cmd_vel_bridge.sh start` bridges only `/cmd_vel` to the Create 3 DDS graph on `l4tbr0`
- `./scripts/robot/run_create3_odom_bridge.sh start` bridges Create 3 wheel odometry back onto the autonomy graph
- `./scripts/robot/run_nav2_with_rtabmap.sh` runs later on the same local autonomy graph

Important sync notes:

- RTAB-Map needs `/odom`, RGB, depth, and camera info that are close in time
- in the validated floor-run flow, RTAB-Map consumes bridged Create 3 odometry by default and still fuses RGB-D for mapping
- `/scan` is optional for mapping in this repo
- the repo prefers `/oak/depth/image_raw` when that aligned depth stream exists live
- if only `/oak/stereo/image_raw` exists, mapping can still work, but it is less trustworthy unless that stream is already aligned to the RGB optical frame
- if the full autonomy stack is accidentally put back on the robot DDS graph over `l4tbr0`, the Create 3 can OOM-kill `create-platform`; keep direct robot DDS access for diagnostics only

## 1) Build image (one-time)

```bash
chmod +x scripts/*.sh
./scripts/build/build_robot_runtime_image.sh
```

Compatibility note: `./scripts/build/build_rtabmap_image.sh` still works, but the preferred entrypoint is `build_robot_runtime_image.sh`.

## 2) Start container

```bash
./scripts/robot/run_robot_runtime_container.sh
```

Expected runtime mode:

- `Runtime container mode: autonomy-local DDS`
- `DOMAIN=42`
- `DDS_IFACE=lo`

`run_robot_runtime_container.sh` mounts this repo into the unified robot runtime container at `/robot_ws`, so the documented `./scripts/...` paths work directly inside Docker. `run_rtabmap_container.sh` remains as a compatibility alias.

### Important Jetson/OAK note

On this Jetson, mounting only `--device /dev/bus/usb:/dev/bus/usb` was **not sufficient** for stable OAK bringup inside Docker. The camera would appear on the host and even work with host-side DepthAI tools, but `depthai_ros_driver` inside Docker would fail with errors like:

- `X_LINK_DEVICE_NOT_FOUND`
- `Cannot find any device with given deviceInfo`
- `Skipping X_LINK_UNBOOTED device`

The working container configuration is now baked into the unified robot runtime launcher path and uses:

- `--privileged`
- `-v /dev:/dev`
- `-v /run/udev:/run/udev:ro`

That broader device exposure was the key fix that allowed the OAK ROS driver to boot and stay attached cleanly in Docker on this machine.

## 3) Launch OAK camera driver

```bash
./scripts/robot/run_oak_camera.sh
```

This can be run from the host; the wrapper will exec into the running robot runtime container.

By default, `run_oak_camera.sh` loads `config/oak_rgbd_sync.yaml` so the depthai ROS driver publishes synchronized RGB and stereo depth frames for RTAB-Map.

Optional:

```bash
PARENT_FRAME=base_link NAME=oak ./scripts/robot/run_oak_camera.sh
```

## 4) Validate camera topics before RTAB-Map

```bash
REQUIRE_ODOM_TOPIC=0 REQUIRE_SCAN_TOPIC=0 ./scripts/robot/ros_health_check.sh
```

Expected minimum set:

- `/oak/rgb/image_raw`
- `/oak/rgb/camera_info`
- a depth topic, for example:
  - `/oak/depth/image_raw`, or
  - `/oak/stereo/image_raw`

Before RTAB-Map starts, `/odom` may still be absent if the odom bridge is not up yet. `/scan` is optional.

## 5) Capture raw bag

```bash
RUN_NAME=$(date +%F)-lab_loop_a ./scripts/robot/record_raw_bag.sh
```

Example with explicit depth topic:

```bash
DEPTH_TOPIC=/oak/depth/image_raw \
RUN_NAME=$(date +%F)-lab_loop_a \
./scripts/robot/record_raw_bag.sh
```

The bag wrapper also applies rosbag QoS overrides for sensor topics and `/tf_static`, which avoids the common Humble issue where best-effort OAK streams or latched static transforms are missed during recording.

## 6) Launch RTAB-Map

```bash
./scripts/robot/run_create3_odom_bridge.sh start
./scripts/robot/run_rtabmap_rgbd.sh
```

If you intentionally want the older pure visual-odometry debug path:

```bash
VISUAL_ODOMETRY=true ./scripts/robot/run_rtabmap_rgbd.sh
```

## 7) Check live RTAB-Map sync and TF after launch

```bash
./scripts/robot/check_rtabmap_sync.sh
CHECK_MAP_ODOM_TF=1 ./scripts/robot/check_rtabmap_sync.sh
```

On 2026-03-25 the validated floor-run path used the split DDS architecture plus the Create 3 odom bridge and produced live `/odom`, `/rtabmap/map`, and ready `odom <- base_link` / `map <- odom` TF while the Create 3 base stayed healthy on its separate DDS graph.

The RTAB-Map wrapper now uses tighter live-sync defaults to reduce stale tuple pairing:

- `topic_queue_size=30`
- `sync_queue_size=30`
- `approx_sync_max_interval=0.02`

## 8) Stop + verify artifacts

```bash
ls -lah runs/$(date +%F)-lab_loop_a/raw
```

## 9) Optional: add Nav2 pathfinding

See `docs/guides/TUTORIAL_nav2_with_rtabmap.md` for launching Nav2 with RTAB-Map localization and sending goals.
