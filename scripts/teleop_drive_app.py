#!/usr/bin/env python3
import os
import select
import sys
import termios
import time
import tty
from dataclasses import dataclass

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rclpy.qos import QoSProfile, ReliabilityPolicy

TOPIC = os.getenv("TOPIC_CMD_VEL", "/cmd_vel")
BASE_LINEAR = float(os.getenv("LINEAR_SPEED", "0.12"))
BASE_ANGULAR = float(os.getenv("ANGULAR_SPEED", "0.8"))
CMD_TIMEOUT = float(os.getenv("CMD_TIMEOUT", "0.35"))
STATUS_HZ = float(os.getenv("STATUS_HZ", "5"))
SHOW_BLOCK_STATUS = os.getenv("SHOW_BLOCK_STATUS", "1") == "1"

LIN_MIN = float(os.getenv("LINEAR_MIN", "0.05"))
LIN_MAX = float(os.getenv("LINEAR_MAX", "0.35"))
ANG_MIN = float(os.getenv("ANGULAR_MIN", "0.3"))
ANG_MAX = float(os.getenv("ANGULAR_MAX", "1.8"))
SPEED_STEP = float(os.getenv("SPEED_STEP", "0.02"))
TURN_STEP = float(os.getenv("TURN_STEP", "0.05"))


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def publish_cmd(pub, vx, wz):
    msg = Twist()
    msg.linear.x = float(vx)
    msg.angular.z = float(wz)
    pub.publish(msg)


def _true_bool_fields(msg):
    fields = []
    for slot in getattr(msg, "__slots__", []):
        name = slot.lstrip("_")
        try:
            val = getattr(msg, name)
        except Exception:
            continue
        if isinstance(val, bool) and val:
            fields.append(name)
    return fields


@dataclass
class TeleopStatus:
    odom_vx: float = 0.0
    odom_wz: float = 0.0
    odom_stamp: float = 0.0
    stop_reason: str = ""
    hazard_reason: str = ""
    kidnap_reason: str = ""

    def block_reason(self):
        reasons = []
        if self.kidnap_reason:
            reasons.append(self.kidnap_reason)
        if self.stop_reason:
            reasons.append(self.stop_reason)
        if self.hazard_reason:
            reasons.append(self.hazard_reason)
        return "; ".join(reasons)


def pop_key(buffer):
    if not buffer:
        return None, buffer

    if buffer.startswith(b"\x1b[A") or buffer.startswith(b"\x1bOA"):
        return "UP", buffer[3:]
    if buffer.startswith(b"\x1b[B") or buffer.startswith(b"\x1bOB"):
        return "DOWN", buffer[3:]
    if buffer.startswith(b"\x1b[C") or buffer.startswith(b"\x1bOC"):
        return "RIGHT", buffer[3:]
    if buffer.startswith(b"\x1b[D") or buffer.startswith(b"\x1bOD"):
        return "LEFT", buffer[3:]

    c = buffer[:1]
    if c in (b"q", b"Q"):
        return "QUIT", buffer[1:]
    if c in (b" ",):
        return "STOP", buffer[1:]
    if c in (b"e", b"E"):
        return "ESTOP", buffer[1:]
    if c in (b"r", b"R"):
        return "RESUME", buffer[1:]
    if c in (b"+", b"="):
        return "LIN_UP", buffer[1:]
    if c in (b"-", b"_"):
        return "LIN_DOWN", buffer[1:]
    if c in (b"]",):
        return "ANG_UP", buffer[1:]
    if c in (b"[",):
        return "ANG_DOWN", buffer[1:]

    if c == b"\x1b" and len(buffer) < 3:
        return None, buffer

    return "IGNORE", buffer[1:]


def draw_help():
    print("\n=== Create 3 Drive App (USB-C / ROS2) ===")
    print("Arrows : drive")
    print("Space  : immediate stop")
    print("e      : ESTOP latch (publish zero until 'r')")
    print("r      : release ESTOP latch")
    print("+ / -  : linear speed up/down")
    print("] / [  : angular speed up/down")
    print("q      : quit")
    print("-----------------------------------------")


def main():
    if not sys.stdin.isatty():
        print("This script requires a TTY (interactive terminal).", file=sys.stderr)
        return 1

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)

    rclpy.init()
    node = rclpy.create_node("create3_drive_app")
    pub = node.create_publisher(Twist, TOPIC, 10)

    status = TeleopStatus()

    def on_odom(msg):
        status.odom_vx = msg.twist.twist.linear.x
        status.odom_wz = msg.twist.twist.angular.z
        status.odom_stamp = time.monotonic()

    qos = QoSProfile(depth=10)
    qos.reliability = ReliabilityPolicy.BEST_EFFORT
    node.create_subscription(Odometry, "/odom", on_odom, qos)

    if SHOW_BLOCK_STATUS:
        try:
            from irobot_create_msgs.msg import HazardDetectionVector, KidnapStatus, StopStatus

            def on_stop(msg):
                flags = _true_bool_fields(msg)
                status.stop_reason = f"stop_status: {','.join(flags)}" if flags else ""

            def on_hazard(msg):
                detections = getattr(msg, "detections", [])
                status.hazard_reason = f"hazard_detection: {len(detections)} active" if detections else ""

            def on_kidnap(msg):
                flags = _true_bool_fields(msg)
                status.kidnap_reason = f"kidnap_status: {','.join(flags)}" if flags else ""

            node.create_subscription(StopStatus, "/stop_status", on_stop, qos)
            node.create_subscription(HazardDetectionVector, "/hazard_detection", on_hazard, qos)
            node.create_subscription(KidnapStatus, "/kidnap_status", on_kidnap, qos)
        except Exception:
            pass

    lin = clamp(BASE_LINEAR, LIN_MIN, LIN_MAX)
    ang = clamp(BASE_ANGULAR, ANG_MIN, ANG_MAX)
    vx = 0.0
    wz = 0.0
    estop = False
    last_cmd = 0.0
    buf = b""

    next_status = 0.0
    status_period = 1.0 / max(1.0, STATUS_HZ)

    draw_help()

    try:
        tty.setcbreak(fd)
        while rclpy.ok():
            ready, _, _ = select.select([sys.stdin], [], [], 0.03)
            if ready:
                chunk = os.read(fd, 64)
                if not chunk:
                    break
                buf += chunk

                while True:
                    key, buf = pop_key(buf)
                    if key is None:
                        break

                    now = time.monotonic()
                    if key == "QUIT":
                        return 0
                    elif key == "STOP":
                        vx, wz = 0.0, 0.0
                        last_cmd = 0.0
                    elif key == "ESTOP":
                        estop = True
                        vx, wz = 0.0, 0.0
                        last_cmd = 0.0
                    elif key == "RESUME":
                        estop = False
                    elif key == "LIN_UP":
                        lin = clamp(lin + SPEED_STEP, LIN_MIN, LIN_MAX)
                    elif key == "LIN_DOWN":
                        lin = clamp(lin - SPEED_STEP, LIN_MIN, LIN_MAX)
                    elif key == "ANG_UP":
                        ang = clamp(ang + TURN_STEP, ANG_MIN, ANG_MAX)
                    elif key == "ANG_DOWN":
                        ang = clamp(ang - TURN_STEP, ANG_MIN, ANG_MAX)
                    elif key == "UP" and not estop:
                        vx, wz = lin, 0.0
                        last_cmd = now
                    elif key == "DOWN" and not estop:
                        vx, wz = -lin, 0.0
                        last_cmd = now
                    elif key == "LEFT" and not estop:
                        vx, wz = 0.0, ang
                        last_cmd = now
                    elif key == "RIGHT" and not estop:
                        vx, wz = 0.0, -ang
                        last_cmd = now

            now = time.monotonic()
            if estop:
                publish_cmd(pub, 0.0, 0.0)
            elif now - last_cmd <= CMD_TIMEOUT:
                publish_cmd(pub, vx, wz)
            else:
                publish_cmd(pub, 0.0, 0.0)

            rclpy.spin_once(node, timeout_sec=0.0)

            if now >= next_status:
                block = status.block_reason()
                sub_count = pub.get_subscription_count()
                age = (now - status.odom_stamp) if status.odom_stamp > 0 else 999.0
                odom_text = f"odom(vx={status.odom_vx:+.2f}, wz={status.odom_wz:+.2f}, age={age:.1f}s)"
                mode = "ESTOP" if estop else "READY"
                warn = f" | block={block}" if block else ""
                print(
                    f"\r[{mode}] lin={lin:.2f} ang={ang:.2f} cmd_subs={sub_count} {odom_text}{warn}   ",
                    end="",
                    flush=True,
                )
                next_status = now + status_period

            time.sleep(0.02)
    finally:
        print()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        for _ in range(6):
            publish_cmd(pub, 0.0, 0.0)
            rclpy.spin_once(node, timeout_sec=0.0)
            time.sleep(0.04)
        node.destroy_node()
        rclpy.shutdown()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
