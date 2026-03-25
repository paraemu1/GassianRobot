# Scripts Index

Use this folder for executable entrypoints. Most day-to-day work should start from one of the menus below rather than calling low-level scripts from memory.

## Main Menus

- `./scripts/gs_tui.sh`: primary Gaussian capture/train/view workflow
- `./scripts/control_center.sh`: Create 3 control, teleop, ROS checks, and guided autonomy startup
- `./scripts/master_tui.sh`: demo/debug umbrella menu that links to both of the above
- `./scripts/teleop_gamecube_hidraw.sh`: GameCube controller teleop for a Mayflash/Nintendo adapter exposed as `/dev/hidraw*`

## Gaussian Workflow

- Capture and prep:
  - `manual_handheld_oak_capture_test.sh`
  - `prepare_gs_input_from_run.sh`
  - `run_handheld_prep_or_train.sh`
- Training lifecycle:
  - `start_gaussian_training_job.sh`
  - `training_job_status.sh`
  - `watch_gaussian_training_job.sh`
  - `stop_gaussian_training_job.sh`
  - `cleanup_stale_training_state.sh`
- Viewer lifecycle:
  - `start_gaussian_viewer.sh`
  - `stop_gaussian_viewer.sh`
- End-to-end helper:
  - `process_train_export.sh`

## Robot / Mapping Workflow

- Preferred unified robot-runtime entrypoints:
  - `build_robot_runtime_image.sh`
  - `run_robot_runtime_container.sh`
- Container and launch helpers inside/against that runtime:
  - `run_rtabmap_container.sh` (compatibility alias / lower-level launcher)
  - `run_create3_cmd_vel_bridge.sh`
  - `run_oak_camera.sh`
  - `run_rtabmap_rgbd.sh`
  - `run_nav2_with_rtabmap.sh`
- Checks and audits:
  - `create3_base_health_check.sh`
  - `create3_motion_ready_check.sh`
  - `ros_health_check.sh`
  - `check_rtabmap_sync.sh`
  - `software_readiness_audit.sh`
  - `preflight_autonomy.sh`
- Teleop and missions:
  - `teleop_drive_app.sh`
  - `teleop_gamecube_hidraw.sh`
  - `teleop_arrow_keys.sh`
  - `teleop_keyboard.sh`
  - `send_nav2_goal.sh`
  - `run_auto_scan_mission.sh`
  - `launch_live_auto_scan.sh`
  - `start_live_auto_scan.sh` (compatibility wrapper)
  - `stop_live_auto_scan.sh` (compatibility wrapper)
  - `status_live_auto_scan.sh` (compatibility wrapper)
  - `create3_dock_control.sh`
  - `generate_live_scan_waypoints.py`

## Run Management

- `init_run_dir.sh`
- `list_runs.sh`
- `delete_run.sh`
- `restore_run.sh`
- `purge_run_trash.sh`

## Build / Validation

- `build_jetson_training_images.sh`
- `build_robot_runtime_image.sh`
- `build_rtabmap_image.sh` (compatibility alias to the robot runtime image build)
- `validate_docker_builds.sh`
- `test_gs_tui.sh`

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
- The preferred full autonomous scan entrypoint is `./scripts/launch_live_auto_scan.sh start`. It starts Docker if needed, starts the runtime container, both Create 3 bridges, OAK, RTAB-Map, Nav2, saves the RTAB-Map database into the run directory, auto-undocks, runs the stop-and-go mission, stops the stack, and then re-docks on a successful mission.
- `launch_live_auto_scan.sh start-only` brings the stack up without motion, `launch_live_auto_scan.sh mission` runs only the mission/closeout on an already-running stack, and `launch_live_auto_scan.sh stop|status` handle shutdown and inspection.
- `run_local_stopgo_scan_mission.sh` is now the default floor-run mission path. It runs an outward-only stop-go survey, captures at survey stops, and then returns by backtracking executed segments instead of capturing again on the way back.
- `launch_live_auto_scan.sh` now runs `create3_motion_ready_check.sh` after undock / settle. That check is meant to catch unsafe cliff readings before the mission starts; a stationary `stop_status` bit by itself is not treated as a hard failure.
- The live mission now treats drive aborts and unsafe cliff readings as boundary events. On a real ledge / obstacle stop, it backtracks toward entry instead of issuing more forward segments into the same blockage.
- `run_auto_scan_mission.sh` remains available for the older Nav2-style waypoint path, but the validated floor-run default is `run_local_stopgo_scan_mission.sh`.
- `create3_dock_control.sh` now supports `status`, `undock`, and `dock` against the robot-native Create 3 actions.
