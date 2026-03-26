# Next Physical Session Runbook: Live RTAB-Map Auto-Scan

Last updated: 2026-03-25

Purpose: bring up the current validated Create 3 + OAK + RTAB-Map + Nav2 stack, run the supervised floor mission, and close out by stopping the stack and re-docking the robot.

## Current validated architecture

- Local autonomy graph:
  - `ROS_DOMAIN_ID=42`
  - `DDS_IFACE=lo`
  - OAK, RTAB-Map, Nav2, and mission control live here.
- Robot graph:
  - `ROS_DOMAIN_ID=0`
  - `DDS_IFACE=l4tbr0`
  - Create 3 base services and status topics live here.
- Bridges:
  - `./scripts/robot/run_create3_cmd_vel_bridge.sh`
  - `./scripts/robot/run_create3_odom_bridge.sh`
- Preferred launcher:
  - `./scripts/robot/launch_live_auto_scan.sh`

Important behavior of the current mission flow:

- auto-undocks before motion
- uses Create 3 wheel odometry for the validated auto-scan path
- runs `create3_motion_ready_check.sh` after undock / settle to catch unsafe cliff starts
- generates short live waypoint files from the current RTAB-Map pose for the outward survey leg
- pauses between moves with explicit zero-velocity holds
- uses a no-recovery Nav2 behavior tree for the live mission
- treats drive aborts and unsafe cliff readings as scan boundaries
- backtracks executed segments toward entry instead of pushing farther into a ledge or obstacle
- stops the autonomy stack and re-docks after a successful mission

## 0. Physical setup and safety gate

Before any commands:

- put the robot on the floor, never on a table or bench
- clear the area immediately around the dock and the first meter in front of the robot
- connect Create 3 to the Jetson over the known-good USB-C path
- connect the OAK to the Jetson with its normal data cable
- power both devices fully on
- keep a human ready to stop motion immediately

Do not continue if any of these are false.

## 1. Robot link and base health

From the Jetson shell:

```bash
cd /home/cam/GassianRobot
chmod +x scripts/*.sh
docker info >/dev/null 2>&1 || sudo systemctl start docker
docker image inspect gassian/robot-runtime:latest >/dev/null 2>&1 || ./scripts/build/build_robot_runtime_image.sh
ip addr show l4tbr0
ping -I l4tbr0 -c 2 192.168.186.2
curl --interface l4tbr0 -I http://192.168.186.2/
./scripts/robot/create3_base_health_check.sh
./scripts/robot/create3_dock_control.sh status
```

Optional robot log check if the base looks unstable:

```bash
curl --interface l4tbr0 -sS -m 20 http://192.168.186.2/logs-raw | \
  grep -E 'Killed process|create-platform|Out of memory|cdc_ncm' || true
```

Expected result:

- `l4tbr0` is `UP`
- ping succeeds to `192.168.186.2`
- `create3_base_health_check.sh` passes
- `create3_dock_control.sh status` can read `dock_visible` / `is_docked`

If base health fails here, do not start autonomy.

## 2. Bring up the stack without motion

Preferred entrypoint:

```bash
cd /home/cam/GassianRobot
RUN_NAME="$(date +%F-%H%M)-live-auto-scan" ./scripts/robot/launch_live_auto_scan.sh start-only
```

This brings up:

- runtime container
- Create 3 `/cmd_vel` bridge
- Create 3 odom bridge
- OAK
- RTAB-Map
- Nav2

Quick verification:

```bash
./scripts/robot/launch_live_auto_scan.sh status
docker exec ros_humble_robot_runtime bash -lc \
  'source /opt/ros/humble/setup.bash && ros2 action list | grep -Fx /navigate_to_pose'
```

Expected result:

- the runtime container is up
- both Create 3 bridges are up
- `/navigate_to_pose` exists

## 3. Final gate before motion

```bash
cd /home/cam/GassianRobot
NEED_ROBOT=1 ./scripts/robot/preflight_autonomy.sh
```

Notes:

- `/scan` is optional for the current RGB-D path
- `launch_live_auto_scan.sh start-only` already performs the same checks during bringup, but this explicit gate is still useful if the stack has been sitting for a while before the mission

## 4. Run the supervised mission

```bash
cd /home/cam/GassianRobot
RUN_NAME="<same-run-name>" ./scripts/robot/launch_live_auto_scan.sh mission
```

The current launcher behavior is:

- undock if needed
- wait for settle
- verify that cliff readings are safe before motion
- generate `runs/<run>/live_scan_waypoints.tsv`
- run the outward stop-and-go mission
- if the robot hits a ledge / obstacle boundary, end the survey and backtrack toward entry
- stop the stack after a successful mission
- dock the robot after a successful mission

Useful artifacts:

- `runs/<run>/rtabmap.db`
- `runs/<run>/live_scan_waypoints.tsv`
- `runs/<run>/logs/auto_scan_mission.log`
- `runs/<run>/logs/rtabmap.log`
- `runs/<run>/logs/nav2.log`

## 5. Manual dock / undock helpers

If you need direct dock control outside the full launcher:

```bash
cd /home/cam/GassianRobot
./scripts/robot/create3_dock_control.sh status
./scripts/robot/create3_dock_control.sh undock
./scripts/robot/create3_dock_control.sh dock
```

## Acceptance criteria

The stack is ready for a supervised live floor run only if all of these are true in the same session:

1. `./scripts/robot/create3_base_health_check.sh` passes.
2. `./scripts/robot/launch_live_auto_scan.sh start-only` completes.
3. `./scripts/robot/launch_live_auto_scan.sh status` shows the runtime and both bridges up.
4. `/navigate_to_pose` exists in the runtime container.
5. `NEED_ROBOT=1 ./scripts/robot/preflight_autonomy.sh` passes.
6. The mission completes without Nav2 recovery loops or RTAB-Map odometry collapse.
7. If the robot encounters a ledge / obstacle boundary, it backtracks instead of continuing to push into it.
8. The robot stops cleanly and re-docks at the end of a successful run.

## Abort conditions

Abort the session if any of these appear:

- `create3_base_health_check.sh` fails
- `logs-raw` shows repeated `Killed process ... create-platform`
- OAK disconnects under light motion
- RTAB-Map loses odometry under motion
- Nav2 starts recovery spinning / backing near the dock
- the launcher reports unsafe cliff readings before motion
- the robot reports unhealthy docking behavior or repeated dock misses
