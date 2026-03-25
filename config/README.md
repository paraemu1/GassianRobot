# Config Index

Checked-in configuration artifacts live here.

## Files

- `oak_rgbd_sync.yaml`: DepthAI ROS driver overrides used by `run_oak_camera.sh` to keep RGB and stereo streams synchronized for RTAB-Map
- `nav2_rtabmap_params.yaml`: conservative Nav2 tuning used by `run_nav2_with_rtabmap.sh` and the live auto-scan launcher
- `scan_waypoints_room_a.tsv`: legacy example waypoint sequence for room scanning and Nav2-style mission helpers
- `scan_waypoints_room_a_conservative.tsv`: checked-in conservative static waypoint example used as the default static mission file

## Guidance

- Keep reusable, non-secret config here.
- Keep per-run state in `runs/<run>/`, not in this folder.
- The preferred live auto-scan flow now generates short mission-specific waypoint files in `runs/<run>/live_scan_waypoints.tsv` from the robot's current RTAB-Map pose instead of relying only on a static checked-in waypoint table.
- The current validated launcher uses those generated waypoints for the outward survey only. The return-to-entry leg is handled by mission backtracking logic, not by duplicating the return path in the generated waypoint file.
- If a script depends on a config file in this folder, document that link in [scripts/README.md](/home/cam/GassianRobot/scripts/README.md) or the relevant guide.
