# First Successful Run: Copy-Paste Commands

Use these from the Jetson shell.
System-level notes from the earlier setup session: `docs/handoff/SYSTEM_STATE_2026-02-17.md`

## Create 3 USB/Ethernet bringup notes (verified 2026-03-24)

Important: the Create 3 does **not** normally appear on this Jetson as `/dev/ttyUSB*` or `/dev/ttyACM*`. The working wired path is **USB Ethernet / network-over-USB**.

Known-good state from this machine:

- Jetson interface: `l4tbr0`
- Jetson IP: `192.168.186.3`
- Create 3 IP: `192.168.186.2`
- Robot firmware: `H.2.6`
- Robot diagnostic DDS settings:
  - `ROS_DOMAIN_ID=0`
  - `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`
  - Fast DDS discovery server disabled
- Autonomy runtime defaults:
  - `ROS_DOMAIN_ID=42`
  - `DDS_IFACE=lo`

Host-side fix that made the wired link work on this Jetson:

- the NVIDIA USB gadget path had to be restored/enabled
- `/opt/nvidia/l4t-usb-device-mode/nv-l4t-usb-device-mode-runtime-start.sh` was patched to honor `/opt/nvidia/l4t-usb-device-mode/IP_ADDRESS_FOR_CREATE3_ROBOT.conf`

Quick verification:

```bash
ip addr show l4tbr0
ping -I l4tbr0 -c 2 192.168.186.2
curl --interface l4tbr0 -I http://192.168.186.2/
```

If the robot is physically connected but not reachable, check these first:

- robot USB/BLE switch is on the correct USB position
- `l4tbr0` exists and is `UP`
- the host still holds `192.168.186.3`
- do **not** chase missing tty devices; this path is networking, not serial

## Validated autonomy architecture (verified 2026-03-25)

- local autonomy graph:
  - `./scripts/run_robot_runtime_container.sh`
  - defaults to `ROS_DOMAIN_ID=42`
  - defaults to `DDS_IFACE=lo`
- robot graph:
  - Create 3 on `ROS_DOMAIN_ID=0` over `l4tbr0`
- bridge:
  - `./scripts/run_create3_cmd_vel_bridge.sh`
  - `./scripts/run_create3_odom_bridge.sh`
  - forwards `/cmd_vel` to the robot and wheel odometry back to the autonomy graph
- mapping:
  - `./scripts/run_rtabmap_rgbd.sh`
  - `/scan` is optional for the validated RGB-D path
- failure signature to remember:
  - if you put the full autonomy stack directly on `l4tbr0`, the robot can OOM-kill `create-platform`
  - first place to confirm that is `http://192.168.186.2/logs-raw`

## 0) Confirm robot firmware and base ROS health

```bash
curl --interface l4tbr0 -sS http://192.168.186.2/home | \
  grep -o 'version="[^"]*"\|rosversionname="[^"]*"'

./scripts/create3_base_health_check.sh
```

Optional OOM/flood check:

```bash
curl --interface l4tbr0 -sS -m 20 http://192.168.186.2/logs-raw | \
  grep -E 'Killed process|create-platform|Out of memory|cdc_ncm' || true
```

## 1) Make scripts executable

```bash
chmod +x scripts/*.sh
```

## 2) Build container images

```bash
./scripts/build_robot_runtime_image.sh
./scripts/build_jetson_training_images.sh
```

## 3) Start the runtime container on the local autonomy graph

```bash
./scripts/run_robot_runtime_container.sh
```

Expected banner:

- `Runtime container mode: autonomy-local DDS`
- `ROS env: RMW=rmw_cyclonedds_cpp DOMAIN=42 LOCALHOST_ONLY=0 DDS_IFACE=lo`

Use direct robot DDS mode only for debugging:

```bash
CREATE3_DIRECT_DDS=1 ./scripts/run_robot_runtime_container.sh
```

## 4) Start the Create 3 bridges

```bash
./scripts/run_create3_cmd_vel_bridge.sh start
./scripts/run_create3_odom_bridge.sh start
```

## 5) Launch the OAK camera driver

```bash
./scripts/run_oak_camera.sh
```

Optional overrides:

```bash
PARENT_FRAME=base_link NAME=oak ./scripts/run_oak_camera.sh
```

## 6) Launch RTAB-Map

```bash
./scripts/run_rtabmap_rgbd.sh
```

If you intentionally want the older pure visual-odometry debug path:

```bash
VISUAL_ODOMETRY=true ./scripts/run_rtabmap_rgbd.sh
```

## 7) Check the local autonomy graph

```bash
./scripts/check_rtabmap_sync.sh
./scripts/ros_health_check.sh
```

Expected:

- `/odom` is present for RTAB-Map and Nav2
- `/map` and `map -> odom` become available after RTAB-Map settles
- `/scan` may still be absent without blocking the RGB-D flow

## 8) Launch Nav2

```bash
./scripts/run_nav2_with_rtabmap.sh
```

Verify the action is visible:

```bash
docker exec ros_humble_robot_runtime bash -lc \
  'source /opt/ros/humble/setup.bash && ros2 action list | sort | grep navigate_to_pose'
```

## 9) Gate before goals or mission

```bash
NEED_ROBOT=1 ./scripts/preflight_autonomy.sh
```

Optional direct robot-domain check:

```bash
docker run --rm --network host gassian/robot-runtime:latest bash -lc '
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
export CYCLONEDDS_URI="<CycloneDDS><Domain><General><NetworkInterfaceAddress>l4tbr0</NetworkInterfaceAddress><DontRoute>true</DontRoute></General></Domain></CycloneDDS>"
ros2 topic info --no-daemon /cmd_vel
'
```

Healthy result on the robot graph:

- `Publisher count: 1`
- `Subscription count: 1`

## 10) Send a Nav2 goal

```bash
./scripts/send_nav2_goal.sh 1.0 0.0 0.0 1.0
```

## 11) Preferred full live mission

```bash
RUN_NAME="$(date +%F-%H%M)-live-auto-scan" ./scripts/launch_live_auto_scan.sh start
```

What this does now:

- starts Docker if needed
- brings up the runtime container and both Create 3 bridges
- starts OAK, RTAB-Map, and Nav2
- auto-undocks if needed
- checks for unsafe cliff readings before motion
- generates short live waypoints from the current RTAB-Map pose for the outward survey
- runs the stop-and-go mission
- backtracks toward entry if a drive abort or ledge / obstacle boundary is hit
- stops the stack after a successful mission
- re-docks after a successful mission

Optional lower-level mission call on an already-running stack:

```bash
RUN_NAME="<same-run-name>" \
GENERATE_LIVE_WAYPOINTS=0 \
WAYPOINT_FILE=./config/scan_waypoints_room_a_conservative.tsv \
./scripts/launch_live_auto_scan.sh mission
```

## Direct robot-domain motion debug

Use this only when you are intentionally talking straight to the Create 3 DDS graph for diagnostics:

```bash
docker run --rm --network host gassian/robot-runtime:latest bash -lc '
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
export CYCLONEDDS_URI="<CycloneDDS><Domain><General><NetworkInterfaceAddress>l4tbr0</NetworkInterfaceAddress><DontRoute>true</DontRoute></General></Domain></CycloneDDS>"
ros2 topic info --no-daemon /cmd_vel
ros2 topic pub --once --wait-matching-subscriptions 1 /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.08}}"
sleep 0.25
ros2 topic pub --once --wait-matching-subscriptions 1 /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}"
'
```

## GameCube controller teleop over hidraw

The Mayflash / Nintendo GameCube adapter on this Jetson currently appears as:

- USB device `057e:0337`
- HID path `/dev/hidraw0`

Working entrypoint:

```bash
./scripts/teleop_gamecube_hidraw.sh
```

Detailed runbook: `docs/operations/GAMECUBE_HIDRAW_TELEOP.md`
