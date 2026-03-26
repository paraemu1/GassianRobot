# Nav2 Pathfinding With RTAB-Map Localization (ROS 2 Humble)

Last updated: 2026-03-25

Use this when you want robot navigation/pathfinding, not just mapping.

## 1) Start the unified robot runtime container

From the host:

```bash
./scripts/robot/run_robot_runtime_container.sh
```

This now starts the local autonomy graph by default:

- `ROS_DOMAIN_ID=42`
- `DDS_IFACE=lo`

## 2) Start the bridges, OAK, and RTAB-Map

From separate host shells:

```bash
./scripts/robot/run_create3_cmd_vel_bridge.sh start
./scripts/robot/run_create3_odom_bridge.sh start
./scripts/robot/run_oak_camera.sh
./scripts/robot/run_rtabmap_rgbd.sh
./scripts/robot/check_rtabmap_sync.sh
```

RTAB-Map should provide:

- `/map` or `/rtabmap/map` depending on launch/remap configuration
- `map -> odom` TF
- `/odom` available for RTAB-Map and Nav2 on the validated wheel-odom-assisted path

Safety:

- If the robot is on a table or elevated surface, do not run motion goals.
- Use a planning-only action first when possible.

Optional combined check after RTAB-Map is running:

```bash
CHECK_MAP_ODOM_TF=1 ./scripts/robot/check_rtabmap_sync.sh
```

## 3) In another shell, start Nav2

```bash
./scripts/robot/run_nav2_with_rtabmap.sh
```

## 4) Preflight checks required before goals

```bash
./scripts/robot/create3_base_health_check.sh
NEED_ROBOT=1 ./scripts/robot/preflight_autonomy.sh
docker exec ros_humble_robot_runtime bash -lc 'source /opt/ros/humble/setup.bash && ros2 topic list | grep -E "^/map$|^/rtabmap/map$|^/odom$"'
docker exec ros_humble_robot_runtime bash -lc 'source /opt/ros/humble/setup.bash && ros2 run tf2_ros tf2_echo odom base_link'
docker exec ros_humble_robot_runtime bash -lc 'source /opt/ros/humble/setup.bash && ros2 run tf2_ros tf2_echo map odom'
```

If `tf2_echo` times out, Nav2 cannot activate controllers yet.

`/scan` is optional for this validated RGB-D path and is not part of the required gate.

## 5) Send a navigation goal

Inside a third shell:

```bash
./scripts/robot/send_nav2_goal.sh 1.0 0.0 0.0 1.0
```

Planning-only check:

```bash
docker exec ros_humble_robot_runtime bash -lc '
source /opt/ros/humble/setup.bash
ros2 action send_goal /compute_path_to_pose nav2_msgs/action/ComputePathToPose \
"{goal:{header:{frame_id:map},pose:{position:{x:1.0,y:0.0,z:0.0},orientation:{z:0.0,w:1.0}}},use_start:false}"'
```

## 6) Useful checks

```bash
docker exec ros_humble_robot_runtime bash -lc 'source /opt/ros/humble/setup.bash && ros2 action list | grep navigate_to_pose'
docker exec ros_humble_robot_runtime bash -lc 'source /opt/ros/humble/setup.bash && ros2 topic list | grep -E "^/plan$|^/cmd_vel$|^/map$|^/rtabmap/map$"'
docker exec ros_humble_robot_runtime bash -lc 'source /opt/ros/humble/setup.bash && ros2 lifecycle nodes'
```

## Notes

- `run_nav2_with_rtabmap.sh` uses Nav2 default params:
  `config/nav2_rtabmap_params.yaml`
- The wrapper scripts default to the unified runtime container name `ros_humble_robot_runtime`, so a fresh host shell can still exec into the live container without manual `ROS_CONTAINER=...` exports.
- `send_nav2_goal.sh` now defaults to the local autonomy graph and prefers the running runtime container instead of falling back to the robot DDS graph.
- The preferred full-floor-run entrypoint is `./scripts/robot/launch_live_auto_scan.sh start` or the split `start-only` + `mission` flow.
- Override params file if needed:

```bash
PARAMS_FILE=/path/to/nav2_params.yaml ./scripts/robot/run_nav2_with_rtabmap.sh
```
