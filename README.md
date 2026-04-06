# GassianRobot

Repository for Jetson-first robotics capture, Gaussian splat training/viewing, and related Create 3 / RTAB-Map / Nav2 workflows.

## Start Here

- Gaussian splat workflow: [docs/guides/GETTING_STARTED_GAUSSIAN_SPLATS.md](/home/cam/GassianRobot/docs/guides/GETTING_STARTED_GAUSSIAN_SPLATS.md)
- Current live RTAB-Map floor-run workflow: [docs/operations/NEXT_PHYSICAL_SESSION_RUNBOOK.md](/home/cam/GassianRobot/docs/operations/NEXT_PHYSICAL_SESSION_RUNBOOK.md)
- Documentation index: [docs/README.md](/home/cam/GassianRobot/docs/README.md)
- Script index: [scripts/README.md](/home/cam/GassianRobot/scripts/README.md)
- Run layout: [runs/README.md](/home/cam/GassianRobot/runs/README.md)
- Config notes: [config/README.md](/home/cam/GassianRobot/config/README.md)

## Repository Layout

- `scripts/`: operational entrypoints, TUI support files, and health checks
- `docs/`: setup guides, validated runbooks, project context, and dated handoff notes
- `runs/`: run directories and outputs for capture, preprocessing, training, and exports
- `config/`: checked-in config artifacts such as waypoint tables
- `docker/`: compose/build support files
- `assets/`: images and other documentation assets

## Container Architecture

- Robot runtime container: the live robot stack for camera bringup, control, RTAB-Map mapping, and Nav2 navigation. Preferred entrypoints are `./scripts/build/build_robot_runtime_image.sh` and `./scripts/robot/run_robot_runtime_container.sh`. The older `build_rtabmap_image.sh` and `run_rtabmap_container.sh` names still work as compatibility aliases.
- Host-side ROS wrappers now default to the unified runtime container name `ros_humble_robot_runtime`. The older `ros_humble_rtabmap` name remains a compatibility alias but is no longer the primary path.
- Training container: the separate Gaussian splat prep, training, export, and viewer workflow. Keep using `./scripts/build/build_jetson_training_images.sh`, `./scripts/gaussian/start_gaussian_training_job.sh`, and `./scripts/gaussian/start_gaussian_viewer.sh`.
- Keep the two flows separate: do live robot runtime work in the robot runtime container, and Gaussian prep/training/viewer work in the training images.

## Common Entry Points

- `./scripts/master_tui.sh`: unified master TUI for robot scan, robot tools, handheld capture, Gaussian workflow, runs, builds, and diagnostics
- `./scripts/master_tui.sh --start-section robot-scan|robot-tools|handheld|gaussian|runs|builds|diagnostics`: jump directly into a section without extra wrapper scripts
- `./scripts/build/build_robot_runtime_image.sh`: preferred robot runtime image build
- `./scripts/robot/run_robot_runtime_container.sh`: preferred robot runtime shell launcher
- `./scripts/build/validate_docker_builds.sh --mode cached --target all`: quick environment validation

## Operational Notes

- Preserve the Jetson viewer launch path in [docs/operations/JETSON_VERIFIED_STATUS_2026-03-16.md](/home/cam/GassianRobot/docs/operations/JETSON_VERIFIED_STATUS_2026-03-16.md). The validated viewer workflow uses `./scripts/gaussian/start_gaussian_viewer.sh` with the Jetson-specific Docker/runtime settings.
- Preserve the Tailscale proxy pattern in [docs/operations/OPENCLAW_TAILSCALE_WEBUI_NOAUTH_SETUP.md](/home/cam/GassianRobot/docs/operations/OPENCLAW_TAILSCALE_WEBUI_NOAUTH_SETUP.md). The working pattern is loopback-only service plus a Tailscale-bound proxy at its own root path.
- As of 2026-03-25, the validated live autonomy architecture is split across two DDS graphs: `run_robot_runtime_container.sh` defaults to a local-only autonomy graph (`ROS_DOMAIN_ID=42`, `DDS_IFACE=lo`) for OAK + RTAB-Map + Nav2, while `run_create3_cmd_vel_bridge.sh` and `run_create3_odom_bridge.sh` bridge motion and wheel odometry to and from the Create 3 DDS graph on `l4tbr0`.
- The previous “robot app wedged” failure mode was traced to DDS traffic saturation over `l4tbr0`: the robot could OOM-kill `create-platform`, drop its `/cmd_vel` subscriber and status topics, and leave the web UI flaky. Use `./scripts/robot/create3_base_health_check.sh` and `http://192.168.186.2/logs-raw` as the first checks before assuming a robot-side reflash is required.
- `/scan` remains optional for the validated RGB-D path. The current acceptance gate is a healthy Create 3 base interface plus live OAK, RTAB-Map, and Nav2 on the isolated autonomy graph. A supervised floor run is still required for final mission signoff.
- The preferred end-to-end floor-run entrypoint is now `./scripts/robot/launch_live_auto_scan.sh start`. The current mission flow uses Create 3 wheel odometry for auto-scan, auto-undocks before motion, runs a local stop-go survey from live RTAB-Map waypoints, treats drive aborts / unsafe cliff readings as scan boundaries, backtracks executed segments instead of pushing farther into an obstacle or ledge, and auto-docks at the end of a successful mission.

## Orientation

If you are new to the repo, read in this order:

1. [README.md](/home/cam/GassianRobot/README.md)
2. [docs/README.md](/home/cam/GassianRobot/docs/README.md)
3. [scripts/README.md](/home/cam/GassianRobot/scripts/README.md)
4. The specific guide or operations note for the workflow you are about to run
