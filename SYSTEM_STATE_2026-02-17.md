# System State Notes (2026-02-17)

This file records critical system-level changes made during setup.

## 1) RTAB-Map / Nav2 setup status
- Docker image built: `gassian/ros2-humble-rtabmap:latest`
- RTAB-Map launch smoke-tested in container.
- Nav2 launch + action server smoke-tested in container.
- New helper scripts:
  - `scripts/build_rtabmap_image.sh`
  - `scripts/run_rtabmap_container.sh`
  - `scripts/record_raw_bag.sh`
  - `scripts/run_rtabmap_rgbd.sh`
  - `scripts/run_nav2_with_rtabmap.sh`
  - `scripts/send_nav2_goal.sh`

## 2) Jetson package-manager recovery
Issue encountered:
- `nvidia-l4t-kernel` postinst failed due OTA payload spec mismatch on `recomputer-orin`.
- `dpkg` was left in broken state.

Recovery applied:
```bash
sudo mkdir -p /opt/nvidia/l4t-packages
sudo touch /opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall
sudo dpkg --configure -a
sudo apt-get -f install -y
```

Protection applied:
```bash
sudo apt-mark hold \
  nvidia-l4t-kernel \
  nvidia-l4t-kernel-dtbs \
  nvidia-l4t-kernel-headers \
  nvidia-l4t-display-kernel
```

Current holds:
- `nvidia-l4t-kernel`
- `nvidia-l4t-kernel-dtbs`
- `nvidia-l4t-kernel-headers`
- `nvidia-l4t-display-kernel`

## 3) Safety note
- Do not run motion goals while robot is on a table.
- Use Nav2 planning-only checks (`ComputePathToPose`) until robot is on floor.
