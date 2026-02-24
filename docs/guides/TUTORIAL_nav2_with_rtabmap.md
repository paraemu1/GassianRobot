# Nav2 Pathfinding With RTAB-Map Localization (ROS 2 Humble)

Last updated: 2026-02-17

Use this when you want robot navigation/pathfinding, not just mapping.

## 1) Start RTAB-Map stack first
Inside the RTAB-Map container:
```bash
source /opt/ros/humble/setup.bash
./scripts/run_rtabmap_rgbd.sh
```

RTAB-Map should provide:
- `/map`
- `map -> odom` TF
- `/odom` from robot odometry

Safety:
- If the robot is on a table/elevated surface, do not run motion goals.
- Use planning-only action first (`ComputePathToPose`).

## 2) In a second shell, start Nav2
Inside the same container/environment:
```bash
source /opt/ros/humble/setup.bash
./scripts/run_nav2_with_rtabmap.sh
```

## 3) Preflight checks (required before goals)
```bash
ros2 topic list | grep -E '^/map$|^/odom$|^/scan$'
ros2 run tf2_ros tf2_echo odom base_link
ros2 run tf2_ros tf2_echo map odom
```

If `tf2_echo` times out, Nav2 cannot activate controllers yet.

## 4) Send a navigation goal
Inside a third shell:
```bash
source /opt/ros/humble/setup.bash
./scripts/send_nav2_goal.sh 1.0 0.0 0.0 1.0
```

Planning-only check (safe while elevated):
```bash
ros2 action send_goal /compute_path_to_pose nav2_msgs/action/ComputePathToPose \
"{goal:{header:{frame_id:map},pose:{position:{x:1.0,y:0.0,z:0.0},orientation:{z:0.0,w:1.0}}},use_start:false}"
```

## 5) Useful checks
```bash
ros2 action list | grep navigate_to_pose
ros2 topic list | grep -E '^/plan$|^/cmd_vel$|^/map$'
ros2 lifecycle nodes
```

## Notes
- `run_nav2_with_rtabmap.sh` uses Nav2 default params:
  `/opt/ros/humble/share/nav2_bringup/params/nav2_params.yaml`
- Override params file if needed:
```bash
PARAMS_FILE=/path/to/nav2_params.yaml ./scripts/run_nav2_with_rtabmap.sh
```
