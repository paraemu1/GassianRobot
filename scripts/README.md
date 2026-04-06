# Scripts Index

Use this folder for executable entrypoints. Most day-to-day work should start from one of the menus below rather than calling low-level scripts from memory.

## Main Menus

- Root `scripts/` keeps one shell launcher plus support files.
- `./scripts/master_tui.sh`: unified master entrypoint for robot scan, robot tools, Gaussian workflow, runs, builds, and diagnostics
- `./scripts/master_ncurses_tui.py`: ncurses implementation behind `master_tui.sh`

## What Each TUI Does

- `./scripts/master_tui.sh`
  The one shell entrypoint in `scripts/`. Use this if you want the full project interface in one place. It owns the robot scan flow, advanced robot tools, handheld capture, Gaussian workflow, runs, builds, and diagnostics.
- `./scripts/master_ncurses_tui.py`
  Ncurses implementation behind `master_tui.sh`. Use `./scripts/master_tui.sh --modern-ui` if you want to force that full-screen interface directly.

## Which One To Use

- Use one launcher for everything: `./scripts/master_tui.sh`
- Jump straight into robot scan: `./scripts/master_tui.sh --start-section robot-scan`
- Jump straight into robot tools: `./scripts/master_tui.sh --start-section robot-tools`
- Jump straight into handheld capture: `./scripts/master_tui.sh --start-section handheld`
- Jump straight into Gaussian workflow: `./scripts/master_tui.sh --start-section gaussian`

## Directory Layout

- `scripts/lib/`: shared shell helpers used by the TUIs and runtime wrappers
- `scripts/build/`: Docker build and validation entrypoints
- `scripts/gaussian/`: Gaussian capture, prep, train, and viewer lifecycle scripts
- `scripts/robot/`: robot runtime, autonomy, teleop, health checks, and mission scripts
- `scripts/run_tools/`: run creation, listing, delete/restore, and trash management
- `scripts/tests/`: non-destructive script and TUI smoke tests

## Gaussian Workflow

- Capture and prep:
  - `scripts/gaussian/manual_handheld_oak_capture_test.sh`
  - `scripts/gaussian/prepare_gs_input_from_run.sh`
  - `scripts/gaussian/run_handheld_prep_or_train.sh`
- Training lifecycle:
  - `scripts/gaussian/start_gaussian_training_job.sh`
  - `scripts/gaussian/training_job_status.sh`
  - `scripts/gaussian/watch_gaussian_training_job.sh`
  - `scripts/gaussian/stop_gaussian_training_job.sh`
  - `scripts/gaussian/cleanup_stale_training_state.sh`
- Viewer lifecycle:
  - `scripts/gaussian/start_gaussian_viewer.sh`
  - `scripts/gaussian/stop_gaussian_viewer.sh`
- End-to-end helper:
  - `scripts/gaussian/process_train_export.sh`

## Robot / Mapping Workflow

- Preferred unified robot-runtime entrypoints:
  - `scripts/build/build_robot_runtime_image.sh`
  - `scripts/robot/run_robot_runtime_container.sh`
- Container and launch helpers inside/against that runtime:
  - `scripts/robot/run_rtabmap_container.sh` (compatibility alias / lower-level launcher)
  - `scripts/robot/run_create3_cmd_vel_bridge.sh`
  - `scripts/robot/run_oak_camera.sh`
  - `scripts/robot/run_rtabmap_rgbd.sh`
  - `scripts/robot/run_nav2_with_rtabmap.sh`
- Checks and audits:
  - `scripts/robot/create3_base_health_check.sh`
  - `scripts/robot/create3_motion_ready_check.sh`
  - `scripts/robot/ros_health_check.sh`
  - `scripts/robot/check_rtabmap_sync.sh`
  - `scripts/build/software_readiness_audit.sh`
  - `scripts/robot/preflight_autonomy.sh`
- Teleop and missions:
  - `scripts/robot/teleop_drive_app.sh`
  - `scripts/robot/teleop_gamecube_hidraw.sh`
  - `scripts/robot/teleop_arrow_keys.sh`
  - `scripts/robot/teleop_keyboard.sh`
  - `scripts/robot/send_nav2_goal.sh`
  - `scripts/robot/run_auto_scan_mission.sh`
  - `scripts/robot/launch_live_auto_scan.sh`
  - `scripts/robot/start_live_auto_scan.sh` (compatibility wrapper)
  - `scripts/robot/stop_live_auto_scan.sh` (compatibility wrapper)
  - `scripts/robot/status_live_auto_scan.sh` (compatibility wrapper)
  - `scripts/robot/create3_dock_control.sh`
  - `scripts/robot/generate_live_scan_waypoints.py`

## Run Management

- `scripts/run_tools/init_run_dir.sh`
- `scripts/run_tools/list_runs.sh`
- `scripts/run_tools/delete_run.sh`
- `scripts/run_tools/restore_run.sh`
- `scripts/run_tools/purge_run_trash.sh`

## Build / Validation

- `scripts/build/build_jetson_training_images.sh`
- `scripts/build/build_robot_runtime_image.sh`
- `scripts/build/build_rtabmap_image.sh` (compatibility alias to the robot runtime image build)
- `scripts/build/validate_docker_builds.sh`
- `scripts/tests/test_gs_tui.sh`
- `scripts/tests/test_operator_tuis.sh`

## Notes

- Shell wrappers and Python helpers intentionally coexist. In several cases the `.sh` file is the stable entrypoint and the `.py` file is the implementation detail.
- For run-aware commands, prefer explicit `--run ...` selection when available. The repo also supports context-aware `latest`, but explicit selection is safer during operations.
- `run_robot_runtime_container.sh` now defaults to an autonomy-local ROS graph (`ROS_DOMAIN_ID=42`, `DDS_IFACE=lo`) to keep OAK + RTAB-Map + Nav2 traffic off the Create 3 USB DDS link. Set `CREATE3_DIRECT_DDS=1` if you explicitly want the old direct-to-robot DDS mode.
- `run_create3_cmd_vel_bridge.sh` forwards `/cmd_vel` from that local autonomy graph onto the Create 3 DDS graph on `l4tbr0`, and `run_create3_odom_bridge.sh` brings Create 3 wheel odometry back onto the autonomy graph.
- `create3_base_health_check.sh` verifies the robot-side ROS base interface directly on domain 0 and fails if `/cmd_vel` lacks a robot subscriber or if key status topics are missing.
- `run_oak_camera.sh` defaults to `config/oak_rgbd_sync.yaml`, which forces synchronized RGB/stereo publication in `depthai_ros_driver` for RTAB-Map.
- `run_robot_runtime_container.sh` is the preferred launcher for the unified robot runtime container and mounts the repo at `/robot_ws`.
- `run_rtabmap_container.sh` remains available as a compatibility/lower-level launcher for the same runtime path.
- `run_oak_camera.sh`, `record_raw_bag.sh`, `check_rtabmap_sync.sh`, `run_rtabmap_rgbd.sh`, `run_nav2_with_rtabmap.sh`, and `send_nav2_goal.sh` can be launched from the host and will prefer the running robot runtime container by default.
- `check_rtabmap_sync.sh` now covers both live timestamp deltas and TF readiness for `odom <- base_link`; set `CHECK_MAP_ODOM_TF=1` after RTAB-Map starts if you also want `map <- odom` checked in the same pass.
- The preferred full autonomous scan entrypoint is `./scripts/robot/launch_live_auto_scan.sh start`. It starts Docker if needed, starts the runtime container, both Create 3 bridges, OAK, RTAB-Map, Nav2, saves the RTAB-Map database into the run directory, auto-undocks, runs the stop-and-go mission, stops the stack, and then re-docks on a successful mission.
- `launch_live_auto_scan.sh start-only` brings the stack up without motion, `launch_live_auto_scan.sh mission` runs only the mission/closeout on an already-running stack, and `launch_live_auto_scan.sh stop|status` handle shutdown and inspection.
- `scripts/` root now keeps one shell launcher: `master_tui.sh`.
- Jump directly into a specific section with `master_tui.sh --start-section robot-scan|robot-tools|handheld|gaussian|runs|builds|diagnostics`.
- `master_ncurses_tui.py` remains the ncurses implementation behind `master_tui.sh`.
- `run_local_stopgo_scan_mission.sh` is now the default floor-run mission path. It runs an outward-only stop-go survey, captures at survey stops, and then returns by backtracking executed segments instead of capturing again on the way back.
- `launch_live_auto_scan.sh` now runs `create3_motion_ready_check.sh` after undock / settle. That check is meant to catch unsafe cliff readings before the mission starts; a stationary `stop_status` bit by itself is not treated as a hard failure.
- The live mission now treats drive aborts and unsafe cliff readings as boundary events. On a real ledge / obstacle stop, it backtracks toward entry instead of issuing more forward segments into the same blockage.
- `run_auto_scan_mission.sh` remains available for the older Nav2-style waypoint path, but the validated floor-run default is `run_local_stopgo_scan_mission.sh`.
- `create3_dock_control.sh` now supports `status`, `undock`, and `dock` against the robot-native Create 3 actions.
