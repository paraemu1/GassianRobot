# Roadmap: Create 3 + RPLIDAR + OAK-D Pro → 3D Gaussian Splatting

Last updated: 2026-02-17

Related tutorial: `TUTORIAL_jetson_setup_and_remote_access.md`
ROS install tutorial: `TUTORIAL_jetson_ros2_stack_install.md`
Training container setup: `TRAINING_DOCKER_SETUP.md`
RTAB-Map setup: `TUTORIAL_rtabmap_setup_and_capture.md`
Nav2 with RTAB-Map: `TUTORIAL_nav2_with_rtabmap.md`

## Current implementation status (2026-02-17)
- RTAB-Map + ROS 2 Humble environment implemented in Docker (`gassian/ros2-humble-rtabmap:latest`).
- Repo scripts added for:
  - RTAB-Map container launch
  - Raw rosbag capture
  - RTAB-Map RGB-D launch (headless-safe by default)
  - Nav2 bringup + goal send helper
- Jetson package-manager recovery completed for a known `nvidia-l4t-kernel` postinst failure path on `recomputer-orin`; kernel packages held to avoid recurrence.

## 0) Decide your “first success” target (pick one)
- **A. Fastest 3DGS demo (recommended):** teleop the robot, record a short RGB video from the OAK, run COLMAP/Nerfstudio to recover camera poses, train splats, export `.ply`.
- **B. Robotics-first:** get reliable SLAM + Nav2 autonomy first, then add capture missions.
- **C. Integrated poses:** use ROS odom/SLAM as pose priors for reconstruction (more complex; do after A/B).

This roadmap assumes you start with **A**, then graduate to **B**, then **C**.

## 1) Bring up ROS 2 + the robot (foundation)
Goal: you can drive the Create 3, and validate core topics on the Jetson (headless checks). Optional: RViz2/rqt on a separate machine later.

Deliverables:
- A working ROS 2 environment on the Jetson (on-robot compute).
- Create 3 connectivity (drive/teleop + `/tf`, `/odom` visible).

Checklist:
- Confirm supported ROS 2 distro for Create 3 and your Jetson OS (L4T R35-based).
- Confirm ROS 2 discovery/networking setup (same LAN; stable Wi‑Fi).
- Confirm time sync strategy if you’ll record multi-sensor bags later.

## 2) Sensor bringup (LiDAR + camera)
Goal: you can visualize LiDAR scans and the OAK camera stream.

Deliverables:
- LiDAR publishing `LaserScan` and a stable `lidar` frame in `/tf`.
- OAK publishing an RGB stream (and optionally depth/IMU) plus `camera_link` frames.

Notes:
- Mount the OAK rigidly; avoid flex (changing extrinsics breaks repeatability).
- Mount the RPLIDAR level and centered if possible; measure its height.

## 3) Mapping + localization (SLAM Toolbox)
Goal: build and save a 2D map you can reliably localize against.

Deliverables:
- Saved occupancy map (`.pgm/.yaml` or equivalent).
- Saved SLAM/Nav parameters you can re-use.

Suggested workflow:
- Teleop a slow loop around the space; keep LiDAR unobstructed.
- Save the map; re-launch and verify you can localize in it.

## 4) Navigation (Nav2)
Goal: send a goal pose and the robot reaches it repeatedly.

Deliverables:
- Working Nav2 config (costmaps, controller, recovery behaviors).
- A “known good” navigation launch preset.

## 5) Capture for 3DGS (first success path)
Goal: produce a clean dataset and a trained splat export.

Deliverables:
- Raw capture (video or image sequence).
- Processed dataset (frames + recovered poses).
- Trained model and exported `.ply`.

Capture tips that matter most:
- Move slowly to avoid blur; lock exposure if you can.
- Maintain overlap and parallax; do at least one full loop around objects.
- Keep the scene static; avoid moving people/monitors.
- Add texture (tape/markers) if surfaces are blank.

## 6) Automation + repeatability (turn it into a pipeline)
Goal: one command (or short script) produces the same outputs every time.

Deliverables:
- A standard dataset folder layout (`runs/<date>-<scene>/...`).
- A recorded “run sheet” (robot config + sensor config + capture notes).
- Scripts for: record → process → train → export.

## 7) Optional: integrate ROS poses as priors
Goal: use `/tf` + `/odom` + SLAM to improve pose estimation and consistency.

Deliverables:
- Time-synced rosbag2 capture (camera + tf + odom + scan).
- A pose export that can be used as priors (or for evaluation).

## Suggested “what to do next”
1. Get ROS 2 running on the Jetson and verify Create 3 teleop.
2. Bring up RPLIDAR and validate `/scan` and `/tf` on the Jetson (headless).
3. Bring up OAK RGB stream and record a 30–60s capture while teleopping.
4. Process/train/export on the Jetson (expect slower runtimes). Optional later: GPU workstation / cloud if approved.
