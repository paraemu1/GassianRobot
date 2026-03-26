#!/usr/bin/env python3
import os
import select
import sys
import time
from dataclasses import dataclass

import rclpy
from geometry_msgs.msg import Twist
from rclpy.qos import QoSProfile, ReliabilityPolicy

TOPIC = os.getenv("TOPIC_CMD_VEL", "/cmd_vel")
DEVICE = os.getenv("GAMECUBE_HIDRAW", "/dev/hidraw0")
PORT_INDEX = int(os.getenv("GAMECUBE_PORT", "0"))
LINEAR_MAX = float(os.getenv("LINEAR_MAX", "0.20"))
ANGULAR_MAX = float(os.getenv("ANGULAR_MAX", "1.2"))
DEADZONE = float(os.getenv("GAMECUBE_DEADZONE", "0.14"))
CMD_TIMEOUT = float(os.getenv("CMD_TIMEOUT", "0.25"))
STATUS_HZ = float(os.getenv("STATUS_HZ", "5.0"))
DEADMAN_BUTTON = os.getenv("DEADMAN_BUTTON", "L").upper()
TURBO_BUTTON = os.getenv("TURBO_BUTTON", "R").upper()
ALLOW_REVERSE = os.getenv("ALLOW_REVERSE", "1") == "1"
USE_C_STICK_TURN = os.getenv("USE_C_STICK_TURN", "0") == "1"

SLOT_SIZE = 9
REPORT_ID_INPUT = 0x21
REPORT_ID_STREAM_ENABLE = bytes([0x13])
CONNECTED_MASK = 0x10
WIRELESS_MASK = 0x20
MAYFLASH_PC_REPORT_LEN = 9


@dataclass
class PadState:
    connected: bool = False
    wireless: bool = False
    a: bool = False
    b: bool = False
    x: bool = False
    y: bool = False
    left: bool = False
    right: bool = False
    down: bool = False
    up: bool = False
    start: bool = False
    z: bool = False
    r: bool = False
    l: bool = False
    stick_x: int = 128
    stick_y: int = 128
    c_x: int = 128
    c_y: int = 128
    trigger_l: int = 0
    trigger_r: int = 0


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def publish_cmd(pub, vx, wz):
    msg = Twist()
    msg.linear.x = float(vx)
    msg.angular.z = float(wz)
    pub.publish(msg)


def axis_norm(raw: int, deadzone: float) -> float:
    value = (float(raw) - 128.0) / 127.0
    value = clamp(value, -1.0, 1.0)
    if abs(value) < deadzone:
        return 0.0
    if value > 0:
        value = (value - deadzone) / (1.0 - deadzone)
    else:
        value = (value + deadzone) / (1.0 - deadzone)
    return clamp(value, -1.0, 1.0)


def parse_slot(slot: bytes) -> PadState:
    if len(slot) != SLOT_SIZE:
        return PadState()
    status = slot[0]
    buttons0 = slot[1]
    buttons1 = slot[2]
    return PadState(
        connected=bool(status & (CONNECTED_MASK | WIRELESS_MASK)),
        wireless=bool(status & WIRELESS_MASK),
        a=bool(buttons0 & 0x01),
        b=bool(buttons0 & 0x02),
        x=bool(buttons0 & 0x04),
        y=bool(buttons0 & 0x08),
        left=bool(buttons0 & 0x10),
        right=bool(buttons0 & 0x20),
        down=bool(buttons0 & 0x40),
        up=bool(buttons0 & 0x80),
        start=bool(buttons1 & 0x01),
        z=bool(buttons1 & 0x02),
        r=bool(buttons1 & 0x04),
        l=bool(buttons1 & 0x08),
        stick_x=slot[3],
        stick_y=slot[4],
        c_x=slot[5],
        c_y=slot[6],
        trigger_l=slot[7],
        trigger_r=slot[8],
    )


def parse_mayflash_pc_report(report: bytes) -> PadState:
    if len(report) != MAYFLASH_PC_REPORT_LEN:
        return PadState()

    buttons0 = report[0]
    buttons1 = report[1]
    hat = report[8]

    up = hat in (0, 1, 7)
    right = hat in (1, 2, 3)
    down = hat in (3, 4, 5)
    left = hat in (5, 6, 7)

    return PadState(
        connected=True,
        wireless=False,
        a=bool(buttons0 & 0x02),
        b=bool(buttons0 & 0x01),
        x=bool(buttons0 & 0x08),
        y=bool(buttons0 & 0x10),
        left=left,
        right=right,
        down=down,
        up=up,
        start=bool(buttons0 & 0x20),
        z=bool(buttons0 & 0x04),
        r=bool(buttons1 & 0x02),
        l=bool(buttons1 & 0x01),
        stick_x=report[2],
        stick_y=report[3],
        c_x=report[4],
        c_y=report[5],
        trigger_l=report[6],
        trigger_r=report[7],
    )


def parse_report(report: bytes, port_index: int) -> PadState:
    if len(report) == MAYFLASH_PC_REPORT_LEN:
        return parse_mayflash_pc_report(report)
    if len(report) < 1 + SLOT_SIZE * 4:
        return PadState()
    if report[0] != REPORT_ID_INPUT:
        return PadState()
    if not 0 <= port_index <= 3:
        return PadState()
    start = 1 + port_index * SLOT_SIZE
    end = start + SLOT_SIZE
    return parse_slot(report[start:end])


def deadman_pressed(pad: PadState) -> bool:
    if DEADMAN_BUTTON == "L":
        return pad.l
    if DEADMAN_BUTTON == "R":
        return pad.r
    if DEADMAN_BUTTON == "Z":
        return pad.z
    if DEADMAN_BUTTON == "A":
        return pad.a
    return pad.l


def turbo_pressed(pad: PadState) -> bool:
    if TURBO_BUTTON == "L":
        return pad.l
    if TURBO_BUTTON == "R":
        return pad.r
    if TURBO_BUTTON == "Z":
        return pad.z
    if TURBO_BUTTON == "A":
        return pad.a
    return pad.r


def compute_command(pad: PadState):
    if not pad.connected:
        return 0.0, 0.0, "disconnected"
    if not deadman_pressed(pad):
        return 0.0, 0.0, f"hold {DEADMAN_BUTTON}"

    forward = -axis_norm(pad.stick_y, DEADZONE)
    turn_src = pad.c_x if USE_C_STICK_TURN else pad.stick_x
    turn = axis_norm(turn_src, DEADZONE)

    if not ALLOW_REVERSE:
        forward = max(0.0, forward)

    scale = 1.0
    if turbo_pressed(pad):
        scale = 1.35
    elif pad.z:
        scale = 0.55

    vx = clamp(forward * LINEAR_MAX * scale, -LINEAR_MAX * 1.35, LINEAR_MAX * 1.35)
    wz = clamp(-turn * ANGULAR_MAX * scale, -ANGULAR_MAX * 1.35, ANGULAR_MAX * 1.35)

    if pad.up:
        vx = max(vx, 0.18)
    if pad.down and ALLOW_REVERSE:
        vx = min(vx, -0.12)
    if pad.left:
        wz = max(wz, 0.9)
    if pad.right:
        wz = min(wz, -0.9)

    return vx, wz, "live"


def open_device(path: str):
    fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    try:
        os.write(fd, REPORT_ID_STREAM_ENABLE)
    except OSError:
        pass
    return fd


def main():
    rclpy.init()
    node = rclpy.create_node("create3_gamecube_hidraw_teleop")
    qos = QoSProfile(depth=10)
    qos.reliability = ReliabilityPolicy.BEST_EFFORT
    pub = node.create_publisher(Twist, TOPIC, qos)

    print("=== Create 3 GameCube Teleop ===")
    print(f"device={DEVICE} port={PORT_INDEX + 1} topic={TOPIC}")
    print(f"deadman={DEADMAN_BUTTON} turbo={TURBO_BUTTON} linear_max={LINEAR_MAX:.2f} angular_max={ANGULAR_MAX:.2f}")
    print("Controls: left stick = drive/turn, hold deadman to move, turbo for more speed, release deadman to stop.")

    fd = None
    last_report_at = 0.0
    last_status_at = 0.0
    pad = PadState()
    exit_code = 0

    try:
        fd = open_device(DEVICE)
        while rclpy.ok():
            ready, _, _ = select.select([fd], [], [], 0.03)
            now = time.monotonic()

            if ready:
                try:
                    report = os.read(fd, 64)
                except BlockingIOError:
                    report = b""
                if report:
                    maybe = parse_report(report, PORT_INDEX)
                    if maybe.connected or report[:1] == bytes([REPORT_ID_INPUT]):
                        pad = maybe
                        last_report_at = now

            vx, wz, reason = compute_command(pad)
            if now - last_report_at > CMD_TIMEOUT:
                vx, wz, reason = 0.0, 0.0, "report timeout"
            publish_cmd(pub, vx, wz)
            rclpy.spin_once(node, timeout_sec=0.0)

            if now - last_status_at >= 1.0 / max(1.0, STATUS_HZ):
                print(
                    f"\rport={PORT_INDEX + 1} connected={'yes' if pad.connected else 'no '} deadman={'yes' if deadman_pressed(pad) else 'no '} "
                    f"vx={vx:+.2f} wz={wz:+.2f} reason={reason:>14} subs={pub.get_subscription_count()}   ",
                    end="",
                    flush=True,
                )
                last_status_at = now

            time.sleep(0.02)
    except KeyboardInterrupt:
        pass
    except PermissionError:
        print(f"\nPermission denied opening {DEVICE}. Pass the device into Docker and/or run with access to hidraw.", file=sys.stderr)
        exit_code = 2
    except FileNotFoundError:
        print(f"\nMissing device: {DEVICE}", file=sys.stderr)
        exit_code = 2
    finally:
        print()
        for _ in range(8):
            publish_cmd(pub, 0.0, 0.0)
            rclpy.spin_once(node, timeout_sec=0.0)
            time.sleep(0.04)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        node.destroy_node()
        rclpy.shutdown()

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
