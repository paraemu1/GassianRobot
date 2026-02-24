# Runbook: what to do next (first end-to-end run)

Last updated: 2026-02-17

Related tutorial: `docs/guides/TUTORIAL_jetson_setup_and_remote_access.md`
ROS install tutorial: `docs/guides/TUTORIAL_jetson_ros2_stack_install.md`
Training container setup: `docs/guides/TRAINING_DOCKER_SETUP.md`
Quick commands: `docs/operations/FIRST_SUCCESS_COMMANDS.md`
Create 3 triage + field notes: `docs/operations/CREATE3_NETWORK_TRIAGE.md`
RTAB-Map setup: `docs/guides/TUTORIAL_rtabmap_setup_and_capture.md`
Nav2 + RTAB-Map pathfinding: `docs/guides/TUTORIAL_nav2_with_rtabmap.md`
Session handoff record: `docs/handoff/SESSION_HANDOFF_2026-02-17.md`

## Current status snapshot (2026-02-17)
- Create 3 networking is working (see `docs/operations/CREATE3_NETWORK_TRIAGE.md`).
- RTAB-Map Docker image is built and smoke-tested.
- Nav2 scripts are in place and smoke-tested.
- Jetson `dpkg` state was recovered after `nvidia-l4t-kernel` postinst failures and L4T kernel packages are held (see ROS stack tutorial for details).

## Step 1 — Confirm your working assumptions (10 minutes)
- Where will ROS 2 run? **Jetson (on-robot)**.
- Laptop/desktop usage: **SSH into the Jetson only** (no ROS 2 tools assumed off-robot).
- Where will training run? **Jetson** (default). Optional later: GPU workstation / cloud (e.g., Hugging Face) if approved.
- What will you record for the first demo? **Single RGB video** from OAK (recommended).

Note: ROS 2 is not an operating system â€” it runs on top of an OS (your Jetson stays Ubuntu / L4T R35-based).

Write down:
- Robot base: iRobot Create 3
- LiDAR: RPLIDAR A1
- Camera: OAK‑D Pro
- Compute: Jetson Orin Nano Developer Kit Rev 5.0 (8GB unified memory, Tegra/L4T R35; powered by onboard battery pack)

## Step 2 — Get the robot controllable (foundation)
Success criteria:
- You can teleop drive the Create 3.
- You can see `/tf` and `/odom` updating.

If you don’t have this yet, stop here and fix networking/discovery first.

## Step 3 — Validate the LiDAR (headless)
Success criteria:
- A `LaserScan` topic is publishing steadily.
- Headless checks (on the Jetson):
  - `ros2 topic list` includes your scan topic (often `/scan`)
  - `ros2 topic hz /scan` shows a stable rate
  - `ros2 topic echo --once /scan` prints a sane message
- A LiDAR frame exists in `/tf` (or you have a known static transform from LiDAR → base).

Pitfalls:
- Bad/missing USB permissions (if connected to Linux).
- Wrong frame id or no static transform from LiDAR → base.

## Step 4 — Validate the OAK RGB stream (and record a short capture)
Success criteria:
- You can validate the RGB stream (headless topic checks, or by producing a video file on the Jetson).
- Headless checks (on the Jetson):
  - `ros2 topic list` shows an `Image` topic for the camera
  - `ros2 topic echo --once <camera_info_topic>` returns camera intrinsics
  - `ros2 topic echo --once <image_topic>` returns data (don’t spam this; it’s large)
- You can record a **30–60 second** capture while moving slowly.

Capture rules:
- Slow motion, lots of overlap, avoid blur.
- Keep scene static; stable lighting.
- Do one full loop plus a small height change if feasible.

## Step 5 — Process + train (on the Jetson)
Success criteria:
- You can extract frames and recover poses (typically via COLMAP in the toolchain you choose).
- You can train a splat model and export `.ply` on the Jetson (expect slower runtimes).

Jetson-first training tips (Orin Nano 8GB):
- Keep the first scene small: 30–60s capture, slow motion, static scene.
- Reduce data size if you hit memory/time limits:
  - Fewer frames (sample a lower FPS)
  - Lower resolution / downscale images
  - Shorter training (fewer iterations) for quick sanity checks
- Plan for long runs: training may take hours; consider running overnight with good cooling.
- Basic health checks while training:
  - Watch free disk space (datasets get large)
  - Monitor thermals/perf (e.g., `tegrastats`)

Optional later (not in scope right now): move training off the robot (workstation/cloud) and keep the Jetson as capture + preprocessing.

Minimum artifact checklist per run:
- Raw capture (video or image sequence)
- Extracted frames
- Camera intrinsics/extrinsics (as produced by the pipeline)
- Recovered poses
- Training config + checkpoints
- Exported `.ply`

## Step 6 — Only after first success: add autonomy + repeatability
Add in this order:
1. `slam_toolbox`: map + save + relaunch localization.
2. Nav2: reliable goal sending.
3. Waypoint mission: “navigate + pause + rotate + record” pattern.

## Safety before Nav2 motion (important)
Current physical risk noted in this session: robot may be on a table. Do this first:
1. Do not run `navigate_to_pose` while elevated.
2. Validate planning-only with `ComputePathToPose` action (no motion command output).
3. Move robot to floor in open area before sending any Nav2 drive goals.

## Quick questions for me (to tailor commands/configs)
1. What ROS 2 distro and OS are you using on the Jetson (L4T R35-based)? Ubuntu is what's on it. I'm not sure what else to provide. I lack knowledge here.
2. Is the RPLIDAR connected to the Jetson, or directly to the Create 3? Ideally it connected with USB but I haven't tested if you can do that yet. 
3. Do you want the OAK stream recorded as a ROS bag, or as a plain video file? Both, maybe, I'm not sure which would be better at this time.
