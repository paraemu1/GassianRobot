# Autonomy Software Setup (Create 3 + RTAB-Map + Nav2)

This project now includes a validated live mission launcher, a split DDS runtime layout, robot-side base health checks, and native dock / undock helpers.

## Architecture

- Local autonomy graph:
  - `./scripts/run_robot_runtime_container.sh`
  - defaults to `ROS_DOMAIN_ID=42`
  - defaults to `DDS_IFACE=lo`
  - runs OAK + RTAB-Map + Nav2 without flooding the Create 3 USB DDS link
- Robot graph:
  - Create 3 remains on `ROS_DOMAIN_ID=0` over `l4tbr0`
- Bridge:
  - `./scripts/run_create3_cmd_vel_bridge.sh`
  - `./scripts/run_create3_odom_bridge.sh`
- Robot base health:
  - `./scripts/create3_base_health_check.sh`
- Robot motion-ready gate:
  - `./scripts/create3_motion_ready_check.sh`
- Robot dock helpers:
  - `./scripts/create3_dock_control.sh`

This split is now the default because running the entire autonomy stack directly on the Create 3 DDS graph could OOM-kill `create-platform` on the robot.

## Main commands

From repo root:

```bash
./scripts/software_readiness_audit.sh
./scripts/create3_base_health_check.sh
./scripts/create3_dock_control.sh status
./scripts/launch_live_auto_scan.sh start-only
./scripts/preflight_autonomy.sh
DRY_RUN=1 ./scripts/launch_live_auto_scan.sh mission
```

## Waypoints and mission shape

Default waypoint file:

- `config/scan_waypoints_room_a_conservative.tsv`

Format:

```text
x y qz qw hold_sec
```

Example line:

```text
0.8 0.0 0.0 1.0 2
```

## Live mission (when robot is connected)

1. Verify Create 3 base health:

```bash
./scripts/create3_base_health_check.sh
```

2. Bring up the split autonomy stack:

```bash
RUN_NAME="$(date +%F-%H%M)-live-auto-scan" ./scripts/launch_live_auto_scan.sh start-only
```

3. Run the final mission gate:

```bash
NEED_ROBOT=1 ./scripts/preflight_autonomy.sh
```

4. Execute mission:

```bash
RUN_NAME="<same-run-name>" ./scripts/launch_live_auto_scan.sh mission
```

Optional:

```bash
RUN_NAME="<same-run-name>" \
GENERATE_LIVE_WAYPOINTS=0 \
WAYPOINT_FILE=./config/scan_waypoints_room_a_conservative.tsv \
./scripts/launch_live_auto_scan.sh mission
```

## Notes

- The mission runner assumes Nav2 action `/navigate_to_pose` is available.
- `/scan` is optional for the validated RGB-D path in this repo.
- The preferred auto-scan path now uses Create 3 wheel odometry bridged onto the local autonomy graph. Pure visual odometry remains available for debugging but is not the validated floor-run default.
- `launch_live_auto_scan.sh mission` now auto-undocks before motion, checks for unsafe cliff starts, and auto-docks after a successful mission.
- The preferred mission flow generates short run-specific waypoint files under `runs/<run>/live_scan_waypoints.tsv` for the outward survey only.
- The validated floor-run path is `run_local_stopgo_scan_mission.sh`, not the older Nav2-style `run_auto_scan_mission.sh`.
- On a drive abort or unsafe cliff boundary during the survey, the mission backtracks executed segments toward entry instead of trying to push farther into the same obstacle or ledge.
- This is software orchestration; tuning, map quality, and obstacle behavior still depend on supervised live robot testing.
- Use `./scripts/easy_autonomy_tui.sh` for operator-facing menu access.
- Use `./scripts/control_center.sh` only when you need the advanced manual/diagnostic tools.
- Use `./scripts/master_tui.sh` only as a simple ncurses launcher into the easy menu, advanced robot tools, or Gaussian workflow.

## Current validation status on this Jetson

Verified on 2026-03-25:

- `./scripts/create3_base_health_check.sh` passed on the live robot
- `NEED_ROBOT=1 ./scripts/preflight_autonomy.sh` passed
- local autonomy graph stayed healthy with OAK + RTAB-Map + Nav2 up
- robot-domain `/cmd_vel` showed both a publisher and a robot subscriber through the bridge
- robot-domain odometry was bridged back onto the autonomy graph for RTAB-Map / Nav2
- `l4tbr0` transmit growth stayed low under the split DDS architecture
- a supervised stop-and-go floor mission completed with live-generated outward-survey waypoints
- a live boundary-limited run hit a ledge / obstacle boundary, backtracked, exited cleanly, and then docked successfully
- the successful mission path auto-undocked, completed, stopped the stack, and re-docked

Bottom line:

- the software path is now correctly split between local autonomy DDS and robot DDS
- the previous Create 3 control-path blocker is fixed
- the current preferred floor-run entrypoint is `./scripts/launch_live_auto_scan.sh`
- the current floor-run behavior is conservative by design: stop-go captures, explicit boundary handling, and no deliberate “push through” recovery behavior
