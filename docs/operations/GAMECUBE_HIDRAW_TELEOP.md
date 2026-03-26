# GameCube `hidraw` Teleop

Use this path when the GameCube adapter appears as a USB HID device on `/dev/hidraw*` instead of `/dev/input/js0`. On this Jetson, the Mayflash adapter in PC mode shows up as `0079:1844`.

The default launcher is Docker-first and uses the unified robot runtime image `gassian/robot-runtime:latest`, so a host ROS install is not required.

## Run

```bash
./scripts/robot/teleop_gamecube_hidraw.sh
```

Optional overrides:

```bash
GAMECUBE_HIDRAW=/dev/hidraw0 \
GAMECUBE_PORT=0 \
DEADMAN_BUTTON=A \
TURBO_BUTTON=R \
LINEAR_MAX=0.20 \
ANGULAR_MAX=1.2 \
./scripts/robot/teleop_gamecube_hidraw.sh
```

Notes:

- If `GAMECUBE_HIDRAW` is not set, the launcher tries to auto-detect the adapter by `HID_ID=0003:00000079:00001844`.
- `GAMECUBE_PORT=0` means adapter port 1. Ports `1`, `2`, and `3` map to physical ports 2-4.
- DDS defaults match the known-good Create 3 USB-network path on `l4tbr0`.

## Controls

- Hold `A` to enable motion
- Left stick: linear drive and turning
- Hold `R` for faster response
- Hold `Z` for precision mode
- Release the deadman button to stop immediately
- `Ctrl-C` exits and sends repeated zero-velocity stop commands

## Known-Good Jetson / Mayflash Setup

On this Jetson, the working path was:

- Mayflash adapter switch set to **PC mode**
- Adapter enumerates as `0079:1844`
- Active controller node was observed on `/dev/hidraw0`
- The adapter exposed multiple `hidraw` nodes, but `/dev/hidraw0` was the one that changed when buttons were pressed
- The Mayflash PC-mode report format here is a **9-byte HID report**, not the Nintendo-style multi-slot report the original script expected
- A live capture while holding `A` showed:
  - idle: `000080808080000008`
  - `A` held: `020080808080000008`
- The teleop parser was updated to understand this 9-byte Mayflash PC-mode format
- The launcher default deadman was changed from `L` to `A` for this adapter so driving works immediately without relying on shoulder-button mapping

Current known-good command:

```bash
GAMECUBE_HIDRAW=/dev/hidraw0 ./scripts/robot/teleop_gamecube_hidraw.sh
```

Expected live startup status now looks like:

- `connected=yes`
- `deadman=no` until `A` is held
- `subs=1` when `/cmd_vel` has the Create 3 subscriber

## Safety

- Start with the robot on the floor in open space
- Keep one hand ready to release the deadman button immediately
- If HID reports stop arriving, the teleop node publishes zero velocity
- If the controller disconnects or the script exits, the teleop path publishes zero velocity

## Minimal Permission Workaround

If opening `/dev/hidraw0` fails with `Permission denied`, use the least-invasive workaround that gets you unblocked:

```bash
sudo ./scripts/robot/teleop_gamecube_hidraw.sh
```

If you only want temporary access to the node for your current user:

```bash
sudo setfacl -m u:$USER:rw /dev/hidraw0
# or, if setfacl is unavailable:
sudo chmod a+rw /dev/hidraw0
```

Those temporary permissions usually disappear on unplug or reboot, which is preferable here to adding persistent udev rules before the path is proven out.

## Quick Checks

Confirm the adapter identity:

```bash
for d in /sys/class/hidraw/hidraw*; do
  [ -e "$d/device/uevent" ] || continue
  echo "=== $d ==="
  cat "$d/device/uevent"
done
```

Expected lines for the adapter used here:

- `HID_ID=0003:00000079:00001844`
- `HID_NAME=mayflash limited MAYFLASH GameCube Controller Adapter`

Confirm ROS visibility to the robot:

```bash
./scripts/robot/ros_health_check.sh
```
