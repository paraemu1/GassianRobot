# Hardware (what I have + what I likely need)

Last updated: 2026-02-06

## Hardware I have with me
- iRobot Create 3 (mobile base)
- RPLIDAR A1 (2D LiDAR)
- Luxonis OAK-D Pro (stereo RGB + depth/IMU via DepthAI)
- NVIDIA Jetson: Orin Nano Developer Kit (Revision 5.0)
  - 8GB unified memory
  - Tegra release / L4T: R35
  - Mounted on the robot and powered by an onboard battery pack

## What I likely still need (recommended)
### Must-have to proceed smoothly
- Laptop/desktop for remote access (SSH)
  - Used to SSH into the Jetson, start/stop runs, and pull logs/datasets off the robot.
  - No off-robot ROS 2 compute is assumed for this project; ROS 2 runs on the Jetson.
- Storage for datasets (fast SSD)
  - 3DGS datasets get large quickly (videos, extracted frames, intermediate COLMAP outputs).
- Cabling + adapters (the “unblockers”)
  - USB 3.0 cable for OAK-D Pro (and a spare)
  - USB cable for RPLIDAR A1 (and a spare)
  - USB hub if your compute device is port-limited
- Mounting hardware
  - Rigid mount for OAK-D Pro (stable extrinsics matter for reconstruction)
  - RPLIDAR mount at a known height/angle, plus basic vibration isolation if possible
  - Basic kit: M3/M4 screws, zip ties, Velcro, double-sided tape
- Power + charging plan
  - Appropriate power delivery for the Jetson (and/or powered USB hub if sensors brown-out)
  - Battery pack plan: capacity/runtime target, mounting, fusing, and a safe shutdown strategy

### Nice-to-have (quality and repeatability)
- Calibration targets
  - Printed checkerboard/Charuco board + a flat backing (for camera calibration / verification)
  - A measuring tape + small bubble level (to document mounts and scene scale)
- Lighting control
  - Simple LED panels or consistent room lighting to avoid flicker and exposure pumping.
- A “texture kit” for low-texture scenes
  - AprilTags/ArUco sheets, painter’s tape, stickers (helps COLMAP/feature tracking).

### Optional upgrades (if you hit limits)
- More capable onboard compute (if your current Jetson struggles with OAK-D Pro + ROS)
  - Mini-PC / NUC / higher-tier Jetson (depends on what you want running onboard vs offboard)
- Better LiDAR (if A1 range/noise becomes the bottleneck for mapping/nav)
  - Upgrading to a higher-end RPLIDAR can improve SLAM robustness in larger spaces.
- Optional: GPU workstation for training (if/when you want faster iteration)
  - Not required for the current Jetson-first workflow; it just speeds up training significantly.
