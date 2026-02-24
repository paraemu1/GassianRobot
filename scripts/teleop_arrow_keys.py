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
LINEAR = float(os.getenv("LINEAR_SPEED", "0.12"))
ANGULAR = float(os.getenv("ANGULAR_SPEED", "0.8"))
CMD_TIMEOUT = float(os.getenv("CMD_TIMEOUT", "0.35"))
DEBUG = os.getenv("DEBUG_TELEOP", "0") == "1"
SHOW_BLOCK_STATUS = os.getenv("SHOW_BLOCK_STATUS", "1") == "1"


def publish_cmd(pub, vx, wz):
    msg = Twist()
    msg.linear.x = vx
    msg.angular.z = wz
    pub.publish(msg)


def dbg(msg):
    if DEBUG:
        print(f"[teleop] {msg}", file=sys.stderr, flush=True)


def info(msg):
    print(f"[status] {msg}", flush=True)


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
    odom_stamp: float = 0.0
    stop_reason: str = ""
    hazard_reason: str = ""
    kidnap_reason: str = ""
    robot_msgs_available: bool = False

    def block_reason(self):
        reasons = []
        if self.kidnap_reason:
            reasons.append(self.kidnap_reason)
        if self.stop_reason:
            reasons.append(self.stop_reason)
        if self.hazard_reason:
            reasons.append(self.hazard_reason)
        if not reasons:
            return ""
        return "; ".join(reasons)


def pop_key(buffer):
    if not buffer:
        return None, buffer

    # Arrow keys can come in ANSI mode (ESC [ A) or application mode (ESC O A).
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

    # Wait for more bytes if this may be an incomplete escape sequence.
    if c == b"\x1b" and len(buffer) < 3:
        return None, buffer

    return "IGNORE", buffer[1:]


def main():
    if not sys.stdin.isatty():
        print("This script requires a TTY (interactive terminal).", file=sys.stderr)
        return 1

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)

    rclpy.init()
    dbg("rclpy.init complete")
    node = rclpy.create_node("arrow_keys_teleop")
    dbg("node created")
    pub = node.create_publisher(Twist, TOPIC, 10)
    dbg("publisher created")
    status = TeleopStatus()

    def on_odom(msg):
        status.odom_vx = msg.twist.twist.linear.x
        status.odom_stamp = time.monotonic()

    qos_best_effort = QoSProfile(depth=10)
    qos_best_effort.reliability = ReliabilityPolicy.BEST_EFFORT
    node.create_subscription(Odometry, "/odom", on_odom, qos_best_effort)

    if SHOW_BLOCK_STATUS:
        try:
            from irobot_create_msgs.msg import (
                HazardDetectionVector,
                KidnapStatus,
                StopStatus,
            )

            status.robot_msgs_available = True

            def on_stop(msg):
                flags = _true_bool_fields(msg)
                status.stop_reason = f"stop_status: {','.join(flags)}" if flags else ""

            def on_hazard(msg):
                detections = getattr(msg, "detections", [])
                if detections:
                    status.hazard_reason = f"hazard_detection: {len(detections)} active"
                else:
                    status.hazard_reason = ""

            def on_kidnap(msg):
                flags = _true_bool_fields(msg)
                status.kidnap_reason = f"kidnap_status: {','.join(flags)}" if flags else ""

            node.create_subscription(StopStatus, "/stop_status", on_stop, qos_best_effort)
            node.create_subscription(HazardDetectionVector, "/hazard_detection", on_hazard, qos_best_effort)
            node.create_subscription(KidnapStatus, "/kidnap_status", on_kidnap, qos_best_effort)
            info("Block diagnostics enabled: /stop_status /hazard_detection /kidnap_status")
        except Exception:
            info(
                "Block diagnostics partial: irobot_create_msgs not installed; "
                "using /odom-only reverse block detection."
            )

    vx = 0.0
    wz = 0.0
    last_cmd = 0.0
    buf = b""
    next_dbg = time.monotonic() + 1.0
    pub_count = 0
    last_down_key_at = 0.0
    last_block_report_at = 0.0

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
                    if key == "QUIT":
                        return 0
                    if key == "UP":
                        vx, wz = LINEAR, 0.0
                        last_cmd = time.monotonic()
                        dbg("key=UP")
                    elif key == "DOWN":
                        vx, wz = -LINEAR, 0.0
                        last_cmd = time.monotonic()
                        last_down_key_at = last_cmd
                        dbg("key=DOWN")
                    elif key == "RIGHT":
                        vx, wz = 0.0, -ANGULAR
                        last_cmd = time.monotonic()
                        dbg("key=RIGHT")
                    elif key == "LEFT":
                        vx, wz = 0.0, ANGULAR
                        last_cmd = time.monotonic()
                        dbg("key=LEFT")

            now = time.monotonic()
            if now - last_cmd <= CMD_TIMEOUT:
                publish_cmd(pub, vx, wz)
            else:
                publish_cmd(pub, 0.0, 0.0)
            pub_count += 1

            rclpy.spin_once(node, timeout_sec=0.0)
            if (
                SHOW_BLOCK_STATUS
                and last_down_key_at > 0.0
                and now - last_down_key_at <= 0.7
                and now - last_block_report_at >= 1.0
                and status.odom_stamp > 0.0
                and now - status.odom_stamp <= 0.5
                and abs(status.odom_vx) < 0.01
            ):
                reason = status.block_reason()
                if reason:
                    info(f"Reverse command blocked (odom vx ~ 0). Reason: {reason}")
                else:
                    info("Reverse command blocked (odom vx ~ 0). Reason unknown (likely safety/cliff state).")
                last_block_report_at = now
            if DEBUG and now >= next_dbg:
                dbg(f"loop alive, subs={pub.get_subscription_count()}, pubs={pub_count}")
                next_dbg = now + 1.0
            time.sleep(0.02)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        for _ in range(5):
            publish_cmd(pub, 0.0, 0.0)
            rclpy.spin_once(node, timeout_sec=0.0)
            time.sleep(0.04)
        node.destroy_node()
        rclpy.shutdown()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
