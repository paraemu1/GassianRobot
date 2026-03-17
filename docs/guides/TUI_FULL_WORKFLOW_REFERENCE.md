# TUI Full Workflow Reference

Launch:

```bash
cd /home/cam/GassianRobot
./scripts/gs_tui.sh
```

Safe mode (no destructive/long actions where supported):

```bash
./scripts/gs_tui.sh --safe-mode
```

## Main Menu
1. Gaussian workflow
2. Run management
3. Docker & environment
4. RTAB-Map / Nav2 / robot ops
5. Diagnostics

## 1) Gaussian Workflow Menu
1. Camera health check
2. Capture handheld scan
3. Prep existing run
4. Start training
5. Watch logs
6. Training status
7. Stop training
8. Start viewer
9. Stop viewer
10. Show exported splat paths

Run selection is explicit for run-based actions.

## 2) Run Management Menu
1. List runs with status badges
2. Inspect run details
3. Delete run (soft delete)
4. Restore deleted run
5. Purge trash older than N days

Soft-delete path:
- `runs/<run>` -> `runs/.trash/<timestamp>-<run>`

## 3) Docker & Environment Menu
1. Build training images (cached)
2. Validate training builds (clean)
3. Build RTAB-Map image
4. Validate all builds

## 4) RTAB-Map / Nav2 / Robot Ops Menu
1. Run RTAB-Map container
2. Run OAK ROS camera
3. Run RTAB-Map RGBD
4. Record raw bag
5. Run Nav2 with RTAB-Map
6. Send Nav2 goal
7. Teleop keyboard
8. Teleop arrows
9. ROS health check

## 5) Diagnostics Menu
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
