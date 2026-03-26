#!/usr/bin/env python3
import argparse
import json
import socket
import sys
from typing import Optional

import rclpy
from geometry_msgs.msg import Twist
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node


def twist_to_dict(msg: Twist) -> dict:
    return {
        "linear": {
            "x": msg.linear.x,
            "y": msg.linear.y,
            "z": msg.linear.z,
        },
        "angular": {
            "x": msg.angular.x,
            "y": msg.angular.y,
            "z": msg.angular.z,
        },
    }


def dict_to_twist(payload: dict) -> Twist:
    msg = Twist()
    linear = payload.get("linear", {})
    angular = payload.get("angular", {})
    msg.linear.x = float(linear.get("x", 0.0))
    msg.linear.y = float(linear.get("y", 0.0))
    msg.linear.z = float(linear.get("z", 0.0))
    msg.angular.x = float(angular.get("x", 0.0))
    msg.angular.y = float(angular.get("y", 0.0))
    msg.angular.z = float(angular.get("z", 0.0))
    return msg


def is_zero_twist(msg: Twist) -> bool:
    return (
        msg.linear.x == 0.0
        and msg.linear.y == 0.0
        and msg.linear.z == 0.0
        and msg.angular.x == 0.0
        and msg.angular.y == 0.0
        and msg.angular.z == 0.0
    )


class CmdVelUdpSender(Node):
    def __init__(self, topic: str, host: str, port: int) -> None:
        super().__init__("create3_cmd_vel_bridge_sender")
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._target = (host, port)
        self.create_subscription(Twist, topic, self._on_twist, 20)
        self.get_logger().info(f"Forwarding {topic} to udp://{host}:{port}")

    def _on_twist(self, msg: Twist) -> None:
        payload = json.dumps(twist_to_dict(msg), separators=(",", ":")).encode("ascii")
        try:
            self._sock.sendto(payload, self._target)
        except OSError as exc:
            self.get_logger().error(f"UDP send failed: {exc}")


class CmdVelUdpReceiver(Node):
    def __init__(
        self,
        topic: str,
        bind_host: str,
        port: int,
        stop_after: float,
        publish_hz: float,
    ) -> None:
        super().__init__("create3_cmd_vel_bridge_receiver")
        self._publisher = self.create_publisher(Twist, topic, 20)
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.bind((bind_host, port))
        self._socket.setblocking(False)
        self._stop_after_ns = int(stop_after * 1e9)
        self._last_rx_ns: Optional[int] = None
        self._last_published = Twist()
        self.create_timer(max(1.0 / publish_hz, 0.02), self._poll_socket)
        self.get_logger().info(f"Publishing udp://{bind_host}:{port} onto {topic}")

    def _poll_socket(self) -> None:
        now_ns = self.get_clock().now().nanoseconds
        saw_packet = False

        while True:
            try:
                data, _addr = self._socket.recvfrom(65535)
            except BlockingIOError:
                break
            except OSError as exc:
                self.get_logger().error(f"UDP receive failed: {exc}")
                return

            saw_packet = True
            self._last_rx_ns = now_ns
            try:
                msg = dict_to_twist(json.loads(data.decode("ascii")))
            except Exception as exc:  # pylint: disable=broad-except
                self.get_logger().warning(f"Dropping invalid packet: {exc}")
                continue

            self._publisher.publish(msg)
            self._last_published = msg

        if saw_packet:
            return

        if self._last_rx_ns is None:
            return

        if now_ns - self._last_rx_ns < self._stop_after_ns:
            return

        if is_zero_twist(self._last_published):
            return

        zero = Twist()
        self._publisher.publish(zero)
        self._last_published = zero


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge /cmd_vel over UDP between ROS domains.")
    parser.add_argument("mode", choices=("send", "recv"))
    parser.add_argument("--topic", default="/cmd_vel")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18911)
    parser.add_argument("--stop-after", type=float, default=0.75)
    parser.add_argument("--publish-hz", type=float, default=25.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rclpy.init(args=None)

    if args.mode == "send":
        node = CmdVelUdpSender(args.topic, args.host, args.port)
    else:
        node = CmdVelUdpReceiver(args.topic, args.host, args.port, args.stop_after, args.publish_hz)

    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        try:
            rclpy.shutdown()
        except Exception:  # pylint: disable=broad-except
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
