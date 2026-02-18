# Create 3 + Jetson Networking Triage (Quick)

Use this when teleop/topics do not appear.

## Field-verified notes (2026-02-17)

### Physical connection that worked
- Use **USB-C (Jetson) ↔ USB-C (Create 3 top USB-C port)**.
- Jetson USB-A → Create 3 USB-C did not enumerate correctly for this setup.
- Create 3 USB/BLE switch must be on **USB**.

### Required MAC for network allowlist
- Create 3 Wi-Fi MAC (`wlan0`): `50:14:79:44:BE:B2`
- Create 3 USB MAC (`usb0`): `CE:47:62:54:95:66` (not used for Wi-Fi allowlist)

### Connect Create 3 to secured Wi-Fi from Jetson (no browser required)
```bash
curl --interface l4tbr0 -sS -i -X POST http://192.168.186.2/wifi-action-change \
  --data-urlencode 'ssids=USIsecuredWIFI' \
  --data-urlencode 'pass=usisecured' \
  --data-urlencode 'countryids=FCC'
```

### Verify the robot got a DHCP lease
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
- Look for `wlan0 ... inet addr:<LAN_IP>`. During this session the working lease became `10.171.3.232`.

### Common failure signature seen
- Association succeeds (`WPA2-PSK`, `CTRL-EVENT-CONNECTED`) but DHCP may initially fail (`udhcpc: no lease`).
- Retry provisioning and wait; this eventually resolved once network-side registration completed.

### Firmware update status from this session
- Starting state: `G.5.3` (`Galactic`)
- Final state: `H.2.6` (`Humble`)

Online URL-trigger update was accepted but did not complete reliably:
```bash
curl --interface l4tbr0 "http://192.168.186.2/firmware-update-action?url=https://edu.irobot.com/create3-humble-latest-fw"
```

Offline upload path succeeded:
```bash
mkdir -p /tmp/create3_fw
cd /tmp/create3_fw
curl -L --fail -o Create3-H.2.6.swu \
  https://github.com/iRobotEducation/create3_docs/releases/download/H.2.6/Create3-H.2.6.swu

curl --interface l4tbr0 -sS -i -X POST \
  -F 'fileupload=@Create3-H.2.6.swu' \
  http://192.168.186.2/firmware-update-action
```

Success log lines:
- `Software updated successfully`
- `SWUPDATE successful`

Version check:
```bash
curl --interface l4tbr0 -sS http://192.168.186.2/home | \
  grep -o 'version="[^"]*"\|rosversionname="[^"]*"'
```

## 1) Same LAN check
- Jetson and Create 3 must be on the same local Wi-Fi/LAN.
- SSH over Tailscale can work for shell access, but ROS discovery usually fails across Tailscale by default.

## 2) DDS consistency check
```bash
echo "RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION"
printenv | grep -E 'RMW|ROS_DOMAIN_ID|CYCLONEDDS' || true
```
- Keep DDS configuration consistent across your sessions.

## 3) Multicast sanity check (Jetson)
```bash
ip a
ip maddr
```
- If multicast looks blocked, discovery may fail.

## 4) ROS graph probe
```bash
ros2 node list
ros2 topic list | sort
ros2 topic list | grep -E '^/tf$|^/odom$|/cmd_vel|/scan|/image' || true
```

## 5) Controlled restart sequence
```bash
# In a new shell, re-source your ROS setup
source /opt/ros/humble/setup.bash
# source ~/your_ws/install/setup.bash

# Re-run checks
./scripts/ros_health_check.sh
```

## 6) If still broken, capture minimal debug bundle
```bash
mkdir -p logs
{
  date
  hostname
  ip a
  printenv | grep -E 'RMW|ROS|CYCLONEDDS'
  ros2 node list
  ros2 topic list
} > logs/create3_net_debug.txt 2>&1
```

Attach `logs/create3_net_debug.txt` to your next troubleshooting pass.
