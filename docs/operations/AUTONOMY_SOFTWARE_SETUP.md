# Autonomy Software Setup (Create 3 + RTAB-Map + Nav2)

This project now includes an autonomous mission runner and preflight checks.

## New commands

From repo root:

```bash
./scripts/software_readiness_audit.sh
./scripts/preflight_autonomy.sh
DRY_RUN=1 ./scripts/run_auto_scan_mission.sh
```

## Waypoints

Default waypoint file:

- `config/scan_waypoints_room_a.tsv`

Format:

```text
x y qz qw hold_sec
```

Example line:

```text
0.8 0.0 0.0 1.0 2
```

## Live mission (when robot is connected)

1. Bring up ROS graph (RTAB-Map + Nav2 + Create 3)
2. Run preflight with robot enforcement:

```bash
NEED_ROBOT=1 ./scripts/preflight_autonomy.sh
```

3. Execute mission:

```bash
./scripts/run_auto_scan_mission.sh
```

Optional:

```bash
WAYPOINT_FILE=./config/scan_waypoints_room_a.tsv \
GOAL_TIMEOUT_SEC=240 \
./scripts/run_auto_scan_mission.sh
```

## Notes

- The mission runner assumes Nav2 action `/navigate_to_pose` is available.
- This is software orchestration; tuning, map quality, and obstacle behavior still depend on live robot testing.
- Use `./scripts/control_center.sh` for menu-driven access.

## Current validation status on this Jetson

Verified on 2026-03-16:
- software readiness audit passed with no hard failures
- Docker daemon reachable
- RTAB-Map image present: `gassian/ros2-humble-rtabmap:latest`
- autonomy scripts present and executable where expected
- RTAB-Map Docker validation passed
- RTAB-Map launch smoke test started successfully

Not yet proven in the same session:
- live robot connectivity
- live OAK topic flow into RTAB-Map
- end-to-end Nav2 mission execution on hardware

Observed blockers during audit/testing:
- `l4tbr0` existed but was down at the time of testing
- Create 3 endpoint was not reachable during the audit
- RTAB-Map launch stayed up but warned about missing topic data, which is expected when camera/odom publishers are not active

Bottom line:
- software path is in place
- live autonomy still requires robot + camera bringup and a full hardware session
