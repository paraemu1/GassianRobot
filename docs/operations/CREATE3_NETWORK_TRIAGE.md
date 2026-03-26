# Create 3 + Jetson Networking Triage (Quick)

Use this when Create 3 topics disappear, `/cmd_vel` has no subscriber, or the robot web UI becomes flaky while OAK, RTAB-Map, or Nav2 are running.

## Field-verified failure mode (2026-03-24)

The key lesson from the latest autonomy session is that the Create 3 can look "half alive" even when the real problem starts on the Jetson side:

- if the full autonomy stack shares the robot DDS graph over `l4tbr0`, high-rate OAK and RTAB-Map traffic can overwhelm the USB DDS link
- the robot may then OOM-kill `create-platform`
- when that happens, `/cmd_vel` often remains visible but loses its subscriber, status topics disappear, and `/home` may hang or refuse connections

Observed evidence from `http://192.168.186.2/logs-raw`:

- `Killed process ... (create-platform)`
- `cdc_ncm ... usb0: kevent 2 may have been dropped`

Do not assume a firmware reflash is required until you check for that pattern.

## Recommended steady-state architecture

- Autonomy graph: `./scripts/robot/run_robot_runtime_container.sh`
  - defaults to `ROS_DOMAIN_ID=42`
  - defaults to `DDS_IFACE=lo`
  - keeps OAK + RTAB-Map + Nav2 traffic off the robot USB DDS link
- Robot graph: Create 3 on `ROS_DOMAIN_ID=0` over `l4tbr0`
- Bridge: `./scripts/robot/run_create3_cmd_vel_bridge.sh start`
  - forwards only `/cmd_vel` from the local autonomy graph to the robot
- Robot health check: `./scripts/robot/create3_base_health_check.sh`
- Direct full-graph DDS on `l4tbr0` is debugging-only now:
  - `CREATE3_DIRECT_DDS=1 ./scripts/robot/run_robot_runtime_container.sh`

## 1) Wired USB sanity check

```bash
ip addr show l4tbr0
ping -I l4tbr0 -c 2 192.168.186.2
curl --interface l4tbr0 -I http://192.168.186.2/
```

Expected:

- `l4tbr0` is `UP`
- Jetson holds `192.168.186.3/24`
- Create 3 replies at `192.168.186.2`

Physical notes that still matter:

- Use **USB-C (Jetson) ↔ USB-C (Create 3 top USB-C port)**
- Create 3 USB/BLE switch must be on **USB**
- do not chase missing `/dev/tty*` devices for this path; it is USB Ethernet, not serial

## 2) Probe the lightweight robot endpoints first

`/home` is not the best first probe when the robot is degraded. Prefer:

```bash
curl --interface l4tbr0 -sS -m 10 http://192.168.186.2/logs-raw | tail -n 40
```

And, when the normal web UI is flaky:

```bash
python3 - <<'PY'
import asyncio, websockets
async def main():
    uri='ws://192.168.186.2/about-ws'
    async with websockets.connect(uri, subprotocols=['about']) as ws:
        await ws.send('HELLO')
        out=''
        while True:
            try: out += await asyncio.wait_for(ws.recv(), timeout=1.2)
            except Exception: break
        print(out)
asyncio.get_event_loop().run_until_complete(main())
PY
```

`about-ws` often keeps working even when `/home` is timing out.

## 3) Check for the DDS flood / OOM signature

```bash
curl --interface l4tbr0 -sS -m 20 http://192.168.186.2/logs-raw | \
  grep -E 'Killed process|create-platform|Out of memory|cdc_ncm' || true
```

If those lines appear, treat the robot as overloaded by host DDS traffic until proven otherwise.

## 4) Switch back to the isolated autonomy graph

Use this as the default recovery path:

```bash
cd /home/cam/GassianRobot
./scripts/robot/run_robot_runtime_container.sh
./scripts/robot/run_create3_cmd_vel_bridge.sh start
```

Then bring up the rest of the stack on the local autonomy graph:

```bash
./scripts/robot/run_create3_odom_bridge.sh start
./scripts/robot/run_oak_camera.sh
./scripts/robot/run_rtabmap_rgbd.sh
./scripts/robot/run_nav2_with_rtabmap.sh
```

## 5) Verify that the robot base recovered

```bash
cd /home/cam/GassianRobot
./scripts/robot/create3_base_health_check.sh
```

Healthy base criteria for this repo:

- `/cmd_vel` has a real robot subscriber
- `/stop_status`, `/hazard_detection`, and `/kidnap_status` are visible
- `/scan` is optional unless a separate laser source is expected in the current setup

If you want to inspect the robot DDS graph directly:

```bash
docker run --rm --network host gassian/robot-runtime:latest bash -lc '
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
export CYCLONEDDS_URI="<CycloneDDS><Domain><General><NetworkInterfaceAddress>l4tbr0</NetworkInterfaceAddress><DontRoute>true</DontRoute></General></Domain></CycloneDDS>"
ros2 topic info --no-daemon /cmd_vel
ros2 topic list | grep -E "^/stop_status$|^/hazard_detection$|^/kidnap_status$|^/scan$"
'
```

## 6) Only then try robot-side restart or reflash

If the robot is still unhealthy after the isolated autonomy graph is in place and `create3_base_health_check.sh` still fails:

1. restart the Create 3 app
2. reboot the Create 3
3. retry the offline `H.2.6` reinstall
4. only after that, escalate to physical power-cycle, cable reseat, or deeper recovery

## Appendix: Wi-Fi and firmware notes still worth keeping

### Required MAC for network allowlist

- Create 3 Wi-Fi MAC (`wlan0`): `50:14:79:44:BE:B2`
- Create 3 USB MAC (`usb0`): `CE:47:62:54:95:66`

### Connect Create 3 to secured Wi-Fi from Jetson

```bash
curl --interface l4tbr0 -sS -i -X POST http://192.168.186.2/wifi-action-change \
  --data-urlencode 'ssids=USIsecuredWIFI' \
  --data-urlencode 'pass=usisecured' \
  --data-urlencode 'countryids=FCC'
```

### Verify the robot got a DHCP lease

Use the `about-ws` snippet above and look for `wlan0 ... inet addr:<LAN_IP>`.

### Firmware update status on this machine

- starting state: `G.5.3`
- final state: `H.2.6`

Offline upload path that succeeded:

```bash
mkdir -p /tmp/create3_fw
cd /tmp/create3_fw
curl -L --fail -o Create3-H.2.6.swu \
  https://github.com/iRobotEducation/create3_docs/releases/download/H.2.6/Create3-H.2.6.swu

curl --interface l4tbr0 -sS -i -X POST \
  -F 'fileupload=@Create3-H.2.6.swu' \
  http://192.168.186.2/firmware-update-action
```

Version check:

```bash
curl --interface l4tbr0 -sS http://192.168.186.2/home | \
  grep -o 'version="[^"]*"\|rosversionname="[^"]*"'
```
