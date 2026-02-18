# Robotics + 3D Gaussian Splatting Project Brief (TurtleBot 4 + OAK-D Pro)

*Compiled 2026-01-29*
Repo notes:
- Current tracked hardware list: `Hardware.md`
- Next-steps runbook + roadmap: `RUNBOOK_next_steps.md`, `ROADMAP.md`

Current deployment note (2026-02-06):
- On-robot compute: Jetson Orin Nano Developer Kit Rev 5.0 (8GB unified memory, Tegra/L4T R35).
- Laptop/desktop is used for SSH into the Jetson only (no ROS 2 compute assumed off-robot).
- ROS 2 runs on top of Ubuntu (it is not an operating system).
## 1. What this project is
Goal: use a mobile robot to capture consistent visual datasets of real environments, then reconstruct photorealistic 3D models using 3D Gaussian Splatting (3DGS). Those reconstructions are intended for viewing and interaction in downstream tools such as Unity and VR headsets.

## 2. Why TurtleBot 4 + OAK-D Pro
TurtleBot 4 provides a ROS 2-native mobile base with navigation tooling (SLAM + Nav2). The OAK-D Pro provides synchronized stereo RGB and optional depth, point cloud, and IMU. This supports autonomy for repeatable coverage plus vision capture for reconstruction.

If you’re using a different ROS 2 mobile base (e.g., iRobot Create 3), the same high-level workflow applies; the main differences are in bringup, frames (`/tf`), and navigation stack configuration.

## 3. Core outcomes and artifacts
- Repeatable capture workflow producing clean datasets: video or images, intrinsics, pose estimates.
- Saved 2D map and navigation configuration.
- Trained 3D Gaussian Splat model exported as `.ply`.
- Quality rubric connecting artifacts back to capture issues.

## 4. Minimum stack
### Hardware
- TurtleBot 4 with 2D LiDAR and onboard camera (OAK-D Pro recommended).
- Jetson-class onboard compute running ROS 2 (Jetson Orin Nano in the current setup).
- Training compute: Jetson by default. Optional later: GPU workstation / cloud if approved.

### Software blocks
- ROS 2 environment on the Jetson (on-robot).
- Robot bringup and inspection: `/tf`, `/scan`, odom, camera streams.
- OAK-D Pro: DepthAI + `depthai-ros`.
- Mapping: `slam_toolbox`.
- Autonomy: `nav2`.
- 3DGS: Nerfstudio (COLMAP + FFmpeg), Splatfacto training, export.

## 5. End-to-end workflow
### Phase A: Setup and networking
1. Physical setup and safety checks.
2. Network and remote access: AP mode, join Wi-Fi, SSH, ROS 2 discovery.
3. Install ROS 2 and create a colcon workspace.

### Phase B: Sensor sanity
1. Bring up robot stack.
2. Verify topics are publishing (headless checks on the Jetson; optional RViz2 later).
3. Verify camera stream is publishing or recordable on the Jetson (optional rqt later).

Note: some OAK launch configs publish RGB preview by default, and depth may require explicit enablement.

### Phase C: Mapping and navigation
1. Build and save a 2D occupancy map.
2. Launch Nav2, localize, send goals.
3. Tune costmaps and recovery if needed.

### Phase D: Capture for 3DGS
- Scene is static, textured, stable lighting.
- Move slowly to reduce blur.
- Ensure overlap.
- Ensure parallax.
- Record about 30 to 90 seconds, then stop.

### Phase E: Process and train
This repo is currently targeting Jetson-first training (slower, resource-constrained) so start small and iterate.
```bash
ns-process-data video --data /path/to/video.mp4 --output-dir /path/to/output_dataset
ns-train splatfacto --data /path/to/output_dataset
ns-export gaussian-splat --load-config <path_to_config.yml> --output-dir exports/splat
```

Jetson constraints to plan around:
- Prefer short captures and fewer frames for the first successful run.
- Downscale images / reduce dataset size if you run out of memory.
- Expect longer runtimes; plan to train overnight with good cooling and stable power.

## 6. What to keep
- Raw captures
- Processed dataset (frames + poses)
- Training outputs and exported `.ply`
- Map + Nav2 parameters

## 7. Capture checklist
- Add texture if needed (stickers, markers).
- Keep lighting stable.
- Recapture if blur.
- Do at least one loop, consider a second height.
- Stop recording quickly to control file size.

## 8. How the class packet maps
- TurtleBot 4 roadmap: setup → OAK integration → SLAM → Nav2.
- 3DGS labs: capture/poses → train/view/export.
- Duckiebot labs: optional perception + control skills.

## 9. Extensions that match the bigger vision
- Waypoint capture missions.
- Optional pose priors from odom.
- RGB-D variants if depth enabled.
- Unity/VR ingestion around `.ply` splats.

## 10. Known friction points
- Depth topics may be missing unless enabled.
- ROS 2 networking discovery issues.
- VRAM limits during training.

## 11. Source files
- Robotics_Tutorials_Packet_TurtleBot4_Duckiebot_GaussianSplatting_v2.pdf
- TurtleBot_4 Course Tutorial and Solution Manual.pdf
- turtlebot4_oakdpro_tutorials_table.pdf
