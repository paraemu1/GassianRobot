#!/usr/bin/env python3
import os
import select
import sys
import termios
import time
import tty

import rclpy
from geometry_msgs.msg import Twist


TOPIC = os.getenv("TOPIC_CMD_VEL", "/cmd_vel")
LINEAR = float(os.getenv("LINEAR_SPEED", "0.12"))
ANGULAR = float(os.getenv("ANGULAR_SPEED", "0.8"))
CMD_TIMEOUT = float(os.getenv("CMD_TIMEOUT", "0.35"))
DEBUG = os.getenv("DEBUG_TELEOP", "0") == "1"


def publish_cmd(pub, vx, wz):
    msg = Twist()
    msg.linear.x = vx
    msg.angular.z = wz
    pub.publish(msg)


def dbg(msg):
    if DEBUG:
        print(f"[teleop] {msg}", file=sys.stderr, flush=True)


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

    vx = 0.0
    wz = 0.0
    last_cmd = 0.0
    buf = b""
    next_dbg = time.monotonic() + 1.0
    pub_count = 0

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
