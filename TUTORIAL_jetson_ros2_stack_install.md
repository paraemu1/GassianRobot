# Tutorial: Jetson ROS 2 Stack Install (Jetson-first, SSH-only)

Last updated: 2026-02-17

This tutorial sets up the on-robot software stack on the Jetson. Your laptop/desktop is only used to SSH into the Jetson.
For Gaussian training container setup tied to RTAB-Map runs, see `TRAINING_DOCKER_SETUP.md`.

Hardware/software assumptions:
- Jetson: Orin Nano Dev Kit Rev 5.0, 8GB unified memory, L4T R35 (Ubuntu-based)
- Robot base: iRobot Create 3 (Create 3 “H.*” releases run ROS 2 Humble)
- Sensors: RPLIDAR A1, OAK-D Pro

## 0) Decide how you’ll run ROS 2 on the Jetson

You have two realistic options on L4T R35 (Ubuntu 20.04 base):

### Option A (recommended): Run ROS 2 Humble in Docker
Pros: easiest installs, matches ROS 2 Humble package availability, reproducible.
Cons: extra “container plumbing” for USB devices and system services.

### Option B: Build ROS 2 Humble from source on the host
Pros: no Docker complexity.
Cons: slower, more dependency friction.

This tutorial starts with Option A. If you want Option B, say so and we’ll tailor it.

## 1) Install baseline utilities (Jetson host)
Run on the Jetson:
```bash
sudo apt update
sudo apt install -y \
  git curl wget ca-certificates gnupg lsb-release \
  build-essential cmake pkg-config \
  python3 python3-pip python3-venv \
  tmux htop jq unzip \
  ripgrep \
  ffmpeg
```

## 2) Time sync (recommended)
Good timestamps matter for bags, SLAM, and reconstruction.

On the Jetson:
```bash
sudo apt install -y chrony
sudo systemctl enable --now chrony
```

## 3) Docker-based ROS 2 Humble (recommended path)

### 3.1 Install Docker (Jetson host)
```bash
sudo apt install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Log out and back in (or reboot) so your user can run `docker` without `sudo`.

Quick check:
```bash
docker run --rm hello-world
```

### 3.1.1 Known Jetson package-manager issue on reComputer Orin (important)
On some `recomputer-orin` setups, `apt` operations can fail in `nvidia-l4t-kernel` postinst with OTA payload mismatch and leave `dpkg` broken.

If that happens, recover with:
```bash
sudo mkdir -p /opt/nvidia/l4t-packages
sudo touch /opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall
sudo dpkg --configure -a
sudo apt-get -f install -y
```

To prevent recurrence until BSP/vendor alignment is fixed:
```bash
sudo apt-mark hold \
  nvidia-l4t-kernel \
  nvidia-l4t-kernel-dtbs \
  nvidia-l4t-kernel-headers \
  nvidia-l4t-display-kernel
```

Verify:
```bash
dpkg --audit
apt-mark showhold
```

### 3.2 NVIDIA container runtime (Jetson host)
On Jetson, GPU-enabled containers typically require NVIDIA’s container runtime/toolkit.

First check if GPU is visible from Docker:
```bash
docker info | grep -nE "Runtimes|nvidia" || true
```

If you don’t see an NVIDIA runtime, we’ll install/configure it when you hit the first GPU/container error (paste the output and we’ll update this tutorial).

### 3.3 Create a ROS container launcher
Create a workspace folder on the Jetson:
```bash
mkdir -p ~/robot_ws/src
```

Run a ROS 2 Humble container with host networking (best for DDS):
```bash
docker run --rm -it \
  --network host \
  --name ros_humble \
  -v ~/robot_ws:/robot_ws \
  -w /robot_ws \
  --device=/dev/bus/usb:/dev/bus/usb \
  --privileged \
  ros:humble-ros-base
```

Inside the container:
```bash
apt update
apt upgrade -y
apt install -y python3-pip
```

## 4) Install ROS packages you’ll likely need (inside the container)

Inside the container, install a minimal “robot bringup” set:
```bash
apt update
apt install -y \
  ros-humble-ros-base \
  ros-humble-tf2-tools \
  ros-humble-robot-state-publisher \
  ros-humble-joint-state-publisher \
  ros-humble-image-transport \
  ros-humble-vision-opencv
```

For navigation + mapping (LiDAR):
```bash
apt install -y \
  ros-humble-nav2-bringup \
  ros-humble-slam-toolbox
```

For RTAB-Map (RGB-D mapping) (optional until camera is verified):
```bash
apt install -y ros-humble-rtabmap-ros
```

## 5) Build your workspace (inside the container)
Inside the container:
```bash
cd /robot_ws
mkdir -p src
```

If you’re adding packages from source later (you can skip this entire block for now):
```bash
apt install -y python3-colcon-common-extensions python3-rosdep python3-vcstool
```

### 5.1 rosdep notes (expected messages)
- `rosdep init` is a one-time setup. If you run it again you’ll see:
  - “default sources list file already exists … 20-default.list”
  - That is OK; it just means it’s already initialized.
- The official `ros:*` Docker images commonly run as `root`, so you may also see:
  - “running 'rosdep update' as root is not recommended”
  - That warning is OK for a container. If you want to remove the warning, we can switch to a non-root user inside the container later.

Initialize rosdep only if needed (first time only):
```bash
if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
  rosdep init
fi
rosdep update
```

### 5.2 Why `colcon build` might show “0 packages”
If `src/` is empty, this is expected:
```text
Summary: 0 packages finished
```

Only run `colcon build` after you add at least one ROS package under `/robot_ws/src`.
```bash
colcon build --symlink-install
```

## 5.3 Checkpoint: are you “stuck”?
If you can run:
```bash
source /opt/ros/humble/setup.bash
ros2 --help
ros2 topic list
```
and you see at least `/rosout` and `/parameter_events`, then ROS 2 is installed and working inside the container.

If `colcon build` prints:
```text
Summary: 0 packages finished
```
that is *not* a failure. It just means you haven’t added any packages under `/robot_ws/src` yet.

## 6) Bringup checks (headless, on the Jetson)

### 6.1 ROS environment
Inside the container:
```bash
source /opt/ros/humble/setup.bash
source /robot_ws/install/setup.bash 2>/dev/null || true
ros2 --help
```

Install the demo nodes (used for a quick local self-test):
```bash
apt update
apt install -y ros-humble-demo-nodes-cpp
```

### 6.2 Create 3 connectivity
Goal: see Create 3 topics over the network.

Inside the container:
```bash
ros2 topic list
```

If you only see `/rosout` and `/parameter_events`, that means ROS 2 is running but you are not yet discovering the robot (or any other nodes).

Common reasons:
- Robot and Jetson are not on the same LAN/Wi-Fi (ROS 2 discovery uses multicast by default).
- You’re SSH’d over Tailscale: ROS 2 discovery typically will *not* work over Tailscale without extra configuration.
- RMW/DDS mismatch or domain ID mismatch.

Quick self-test (proves ROS 2 tools work locally):
```bash
ros2 run demo_nodes_cpp talker
```
In a second shell (same container, same environment):
```bash
ros2 run demo_nodes_cpp listener
```

If you see talker/listener messages, the ROS install is fine and the next work is robot networking/DDS configuration.

## 9) What’s next (recommended order)

Now that ROS 2 works locally in the container, the next steps are:

1) **Connect the Jetson to the same Wiâ€‘Fi/LAN as the Create 3**
   - ROS 2 discovery uses multicast by default.
   - If you are SSHâ€™d in via Tailscale, thatâ€™s fine for SSH, but ROS 2 discovery to the robot usually wonâ€™t work over Tailscale without extra configuration. Do the robot networking on the local LAN first.

2) **Switch to CycloneDDS (often the least painful for robot discovery)**
Inside the container:
```bash
apt update
apt install -y ros-humble-rmw-cyclonedds-cpp
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
```

3) **Test multicast (quick signal that discovery can work)**
In one shell:
```bash
ros2 multicast receive
```
In another shell:
```bash
ros2 multicast send
```

4) **Try discovering the Create 3**
```bash
ros2 topic list
ros2 node list
```

If you still only see `/rosout` and `/parameter_events`, paste:
- Whether Jetson + Create 3 are on the same Wiâ€‘Fi network
- Output of `ip a` (Jetson host)
- Output of `ros2 multicast receive` + `ros2 multicast send` (container)

### 6.3 LiDAR publishing
Once the RPLIDAR driver is installed/launched, verify:
```bash
ros2 topic hz /scan
ros2 topic echo --once /scan
```

### 6.4 OAK camera publishing
Once the OAK driver is installed/launched, verify:
```bash
ros2 topic list | grep -nE "image|camera_info"
ros2 topic echo --once <camera_info_topic>
```

## 7) What to paste to me when something fails
When you hit an error, paste:
1) The exact command you ran
2) The full error output
3) Output of:
   - `lsb_release -a`
   - `cat /etc/nv_tegra_release`
   - `docker info | grep -nE "Runtimes|nvidia" || true`
   - `ip a`

I’ll use that to troubleshoot and keep this tutorial updated.

## 8) Next: sensor-specific tutorials
After this is stable, we’ll add separate tutorials for:
- Create 3 networking + DDS config (CycloneDDS vs FastDDS)
- RPLIDAR A1 ROS 2 driver setup
- OAK-D Pro + depthai-ros setup
- RTAB-Map configuration for OAK-D Pro
