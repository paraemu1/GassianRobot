# TUI Full Workflow Reference

Launch:

```bash
cd /home/cam/GassianRobot
./scripts/master_tui.sh
```

Safe mode (no destructive/long actions where supported):

```bash
./scripts/master_tui.sh --safe-mode
```

## Main Menu
1. Scan a room with the robot
2. Advanced robot tools
3. Capture with handheld camera
4. Make a 3D browser view from a saved run
5. Saved runs
6. Build and setup
7. Troubleshooting

Jump straight into a section with the same root launcher:

```bash
./scripts/master_tui.sh --start-section robot-scan
./scripts/master_tui.sh --start-section robot-tools
./scripts/master_tui.sh --start-section handheld
./scripts/master_tui.sh --start-section gaussian
./scripts/master_tui.sh --start-section runs
./scripts/master_tui.sh --start-section builds
./scripts/master_tui.sh --start-section diagnostics
```

## 1) Robot Scan Menu
1. Start a room scan now
2. Get ready to scan without moving yet
3. Start the prepared scan
4. Show robot and scan status
5. Show previous robot scans
6. Send robot to dock
7. Undock robot
8. Explain robot scan

## 2) Robot Tools Menu
1. Check robot connection
2. Run robot health check
3. Drive robot manually
4. Drive with GameCube controller
5. Drive with arrow keys
6. Drive with keyboard
7. Check ROS health
8. Run autonomy preflight check
9. Check software setup
10. Show advanced startup notes
11. Start robot runtime
12. Start camera driver
13. Start live mapping
14. Record raw sensor data
15. Start navigation with live map
16. Send robot to a goal

## 3) Handheld Capture Menu
1. Check camera health
2. Start handheld capture
3. Explain handheld capture

## 4) Gaussian Workflow Menu
1. Guided status and next step
2. Choose guided run
3. Prep existing run
4. Start training
5. Start Jetson gsplat training
6. Watch logs
7. Training status
8. Stop training
9. Start viewer and open browser
10. Start viewer only
11. Stop viewer
12. Show exported splat paths

Run selection is explicit for run-based actions.

## 5) Run Management Menu
1. List runs with status badges
2. Inspect run details
3. Delete run (soft delete)
4. Restore deleted run
5. Purge trash older than N days

Soft-delete path:
- `runs/<run>` -> `runs/.trash/<timestamp>-<run>`

## 6) Builds Menu
1. Build training images (cached)
2. Validate training builds (clean)
3. Build robot runtime image
4. Validate all builds

## 7) Diagnostics Menu
1. Run TUI self-test
2. Show Docker runtime status
3. Show viewer containers
4. Cleanup stale training pid/status

## Run Eligibility Logic
Run badges and latest-selection filters use these checks:
- `trainable`: `raw/capture.mp4` or `gs_input.env`
- `viewer-ready`: any `checkpoints/**/config.yml`
- `exported`: `exports/splat/splat.ply`
- `train-logs`: `logs/train_job.latest.log` or `logs/train_job_*.log`
- `train-metadata`: pid/status/log metadata exists

## Why `camera_health` is excluded from training
`runs/camera_health` is not trainable unless it has the required trainable markers.
Training scripts now target latest **trainable** run, not latest directory by modification time.

## Troubleshooting Quick Tree
1. `watch logs` says no active process:
   - Run `training status` for the same run.
2. Status is `exited`:
   - Job started and failed quickly. Read latest log.
3. Status is `never-started`:
   - No job was launched for that run.
4. Wrong run selected:
   - Re-run from TUI and choose run explicitly.
